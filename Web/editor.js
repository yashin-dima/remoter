// Веб-половина Remoter: Monaco (движок VS Code) плюс тонкий мост в Swift.
// Swift вызывает window.Remoter.*, обратно летят события через postMessage.
(function () {
  'use strict';

  const post = (m) => window.webkit.messageHandlers.bridge.postMessage(m);

  // Ошибки внутри WebView иначе уходят в никуда: консоли у нас нет, и сломавшийся Monaco
  // выглядел бы просто как «diff не появился». Копим для инспектора и шлём в Swift —
  // там они попадают в лог приложения.
  window.__errors = [];
  function reportError(text) {
    window.__errors.push(text);
    try { post({ t: 'error', text: text }); } catch (_) { /* моста нет (страница вне WKWebView) */ }
  }
  window.addEventListener('error', (e) => reportError(String(e.message || e.error)));
  window.addEventListener('unhandledrejection', (e) => reportError('promise: ' + String(e.reason)));

  const elSingle = document.getElementById('single');
  const elDiff = document.getElementById('diff');
  const elMsg = document.getElementById('msg');

  let singleEditor = null;
  let diffEditor = null;

  // Состояние каждой открытой вкладки: свои модели, свой скролл, своя история отмены.
  // Без этого переключение вкладок выбрасывало бы в начало файла и стирало undo —
  // а вкладки для того и нужны, чтобы прыгать между файлами, не теряя место.
  const panes = new Map(); // path -> { mode, models, viewState, cleanVersionId, editable }

  // Сколько вкладок держим в памяти: держать модели полусотни файлов незачем.
  const MAX_PANES = 20;
  // Размер шрифта до прихода настройки из приложения.
  const DEFAULT_FONT_SIZE = 13;
  // Высота строки считается от размера шрифта, иначе при крупном шрифте строки
  // налезали бы друг на друга. Единственное место, где живёт множитель.
  const LINE_HEIGHT_FACTOR = 1.55;

  let active = null; // path
  let dark = true;
  let sideBySide = true;
  let suppressDirty = false;
  let fontSize = DEFAULT_FONT_SIZE;

  const lineHeightFor = (size) => Math.round(size * LINE_HEIGHT_FACTOR);

  const options = () => ({
    automaticLayout: true,
    fontSize: fontSize,
    lineHeight: lineHeightFor(fontSize),
    fontFamily: '"SF Mono", Menlo, Monaco, monospace',
    fontLigatures: false,
    minimap: { enabled: true, renderCharacters: false },
    scrollBeyondLastLine: false,
    smoothScrolling: true,
    renderWhitespace: 'selection',
    renderLineHighlight: 'line',
    scrollbar: { verticalScrollbarSize: 10, horizontalScrollbarSize: 10 },
    padding: { top: 8, bottom: 8 },
  });

  // --- вспомогательное -------------------------------------------------

  function showPane(which) {
    elSingle.style.display = which === 'view' ? 'block' : 'none';
    elDiff.style.display = which === 'diff' ? 'block' : 'none';
    elMsg.style.display = which === 'msg' ? 'flex' : 'none';
  }

  // Язык определяем через реестр самого Monaco, а не своей таблицей расширений:
  // он и так знает про все ~90 языков, включая файлы без расширения вроде Dockerfile.
  function languageFor(path) {
    const name = (path || '').split('/').pop();
    const dot = name.lastIndexOf('.');
    // Расширения в реестре Monaco — в нижнем регистре; Main.SWIFT тоже должен подсветиться.
    const ext = dot > 0 ? name.slice(dot).toLowerCase() : '';
    for (const lang of monaco.languages.getLanguages()) {
      if (lang.filenames && lang.filenames.indexOf(name) >= 0) return lang.id;
      if (ext && lang.extensions && lang.extensions.indexOf(ext) >= 0) return lang.id;
    }
    return 'plaintext';
  }

  function editorFor(mode) {
    return mode === 'diff' ? ensureDiff() : ensureSingle();
  }

  function modifiedModel(pane) {
    return pane.mode === 'diff' ? pane.models.modified : pane.models.model;
  }

  // Грязность считаем по версии undo-стека, а не сравнением всего текста:
  // getValue() на каждое нажатие клавиши — это O(размера файла), на большом
  // файле ввод начинал бы лагать.
  function markClean(pane) {
    pane.cleanVersionId = modifiedModel(pane).getAlternativeVersionId();
  }

  function isDirty(pane) {
    return modifiedModel(pane).getAlternativeVersionId() !== pane.cleanVersionId;
  }

  function watchDirty(pane, path) {
    modifiedModel(pane).onDidChangeContent(() => {
      if (suppressDirty) return;
      post({ t: 'dirty', path, dirty: isDirty(pane) });
    });
  }

  // Полная замена текста с сохранением истории отмены: setValue стирал бы undo-стек,
  // и после каждого живого обновления с сервера ⌘Z переставал бы работать.
  function replaceAll(model, text) {
    model.pushEditOperations(
      [],
      [{ range: model.getFullModelRange(), text }],
      () => null
    );
  }

  // Существующая вкладка получает свежее содержимое с сервера.
  // Несохранённые правки пользователя не трогаем никогда.
  function adoptContent(pane, text) {
    const model = modifiedModel(pane);
    if (model.getValue() === text) {
      // Текст уже совпал (типичный случай — сразу после ⌘S): принимаем как чистую базу.
      markClean(pane);
      return true;
    }
    if (isDirty(pane)) return false;
    suppressDirty = true;
    replaceAll(model, text);
    suppressDirty = false;
    markClean(pane);
    return true;
  }

  function doSave() {
    if (!active) return;
    const pane = panes.get(active);
    if (!pane) return;
    post({ t: 'save', path: active, content: modifiedModel(pane).getValue() });
  }

  function bindSave(editor) {
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, doSave);
  }

  function reportStats(path) {
    if (!diffEditor) return;
    const changes = diffEditor.getLineChanges() || [];
    let added = 0, removed = 0;
    for (const c of changes) {
      if (c.modifiedEndLineNumber > 0) added += c.modifiedEndLineNumber - c.modifiedStartLineNumber + 1;
      if (c.originalEndLineNumber > 0) removed += c.originalEndLineNumber - c.originalStartLineNumber + 1;
    }
    post({ t: 'stats', path, added, removed });
  }

  function ensureSingle() {
    if (!singleEditor) {
      singleEditor = monaco.editor.create(elSingle, options());
      bindSave(singleEditor);
    }
    return singleEditor;
  }

  function ensureDiff() {
    if (!diffEditor) {
      diffEditor = monaco.editor.createDiffEditor(elDiff, Object.assign(options(), {
        renderSideBySide: sideBySide,
        originalEditable: false,
        // Пробелы в конце строк — тоже изменение: скрывать их значит врать про diff.
        ignoreTrimWhitespace: false,
        renderIndicators: true,
        diffWordWrap: 'off',
      }));
      diffEditor.onDidUpdateDiff(() => { if (active) reportStats(active); });
      bindSave(diffEditor.getModifiedEditor());
    }
    return diffEditor;
  }

  /// Сохраняем позицию текущей вкладки перед уходом с неё.
  function stashActive() {
    if (!active) return;
    const pane = panes.get(active);
    if (!pane) return;
    const editor = pane.mode === 'diff' ? diffEditor : singleEditor;
    if (editor) pane.viewState = editor.saveViewState();
  }

  function attach(path) {
    const pane = panes.get(path);
    if (!pane) return;

    // Показанная вкладка уходит в конец очереди вытеснения (LRU, а не FIFO):
    // иначе вытеснялась бы самая используемая вкладка, просто открытая первой.
    panes.delete(path);
    panes.set(path, pane);

    const editor = editorFor(pane.mode);
    suppressDirty = true;
    if (pane.mode === 'diff') {
      editor.setModel({ original: pane.models.original, modified: pane.models.modified });
    } else {
      editor.setModel(pane.models.model);
    }
    editor.updateOptions({ readOnly: !pane.editable });
    suppressDirty = false;

    if (pane.viewState) editor.restoreViewState(pane.viewState);

    active = path;
    showPane(pane.mode);
    post({ t: 'dirty', path, dirty: isDirty(pane) });
    if (pane.mode === 'diff') reportStats(path);
  }

  /// Старые вкладки выбывают, но активную и несохранённые не трогаем:
  /// dispose модели с правками пользователя — молчаливая потеря его текста.
  function evictIfNeeded() {
    if (panes.size <= MAX_PANES) return;
    for (const path of Array.from(panes.keys())) {
      if (panes.size <= MAX_PANES) return;
      if (path === active) continue;
      if (isDirty(panes.get(path))) continue;
      api.closePane({ path });
    }
  }

  // --- API для Swift ---------------------------------------------------

  const api = {
    showFile(p) {
      stashActive();

      let pane = panes.get(p.path);
      if (pane && pane.mode === 'view') {
        // Повторный показ того же файла: принимаем свежее содержимое,
        // но несохранённые правки пользователя не затираем.
        pane.editable = p.editable;
        adoptContent(pane, p.content);
      } else {
        if (pane) api.closePane({ path: p.path });
        const model = monaco.editor.createModel(p.content, languageFor(p.path));
        pane = {
          mode: 'view',
          models: { model },
          viewState: null,
          cleanVersionId: model.getAlternativeVersionId(),
          editable: p.editable,
        };
        panes.set(p.path, pane);
        watchDirty(pane, p.path);
      }
      attach(p.path);
      evictIfNeeded();
    },

    showDiff(p) {
      stashActive();

      let pane = panes.get(p.path);
      if (pane && pane.mode === 'diff') {
        pane.editable = p.editable;
        if (pane.models.original.getValue() !== p.original) {
          pane.models.original.setValue(p.original);
        }
        adoptContent(pane, p.modified);
      } else {
        if (pane) api.closePane({ path: p.path });
        const lang = languageFor(p.path);
        const modified = monaco.editor.createModel(p.modified, lang);
        pane = {
          mode: 'diff',
          models: {
            original: monaco.editor.createModel(p.original, lang),
            modified: modified,
          },
          viewState: null,
          cleanVersionId: modified.getAlternativeVersionId(),
          editable: p.editable,
        };
        panes.set(p.path, pane);
        watchDirty(pane, p.path);
      }
      attach(p.path);
      evictIfNeeded();
    },

    // Подмена текста без пересоздания моделей: позиция скролла и курсор остаются на месте.
    // Именно это делает обновление «живым», когда Claude правит файл на сервере, —
    // иначе на каждой его правке нас выбрасывало бы в начало файла.
    update(p) {
      const pane = panes.get(p.path);
      if (!pane) return;

      const model = modifiedModel(pane);

      // Текст на экране уже совпал с серверным — типичный случай сразу после ⌘S:
      // Swift записал файл и присылает его же обратно. Принимаем как новую базу и гасим
      // dirty, иначе вкладка оставалась бы «грязной» навсегда и блокировала live-обновления.
      if (model.getValue() === p.modified) {
        markClean(pane);
        if (pane.mode === 'diff' && p.original !== undefined
            && pane.models.original.getValue() !== p.original) {
          pane.models.original.setValue(p.original);
        }
        post({ t: 'dirty', path: p.path, dirty: false });
        return;
      }

      // Последний рубеж против потери набранного. Swift и так не присылает update, пока файл
      // «грязный», но флаг грязности прилетает сюда асинхронно: между первым нажатием клавиши
      // и приходом флага есть щель в несколько миллисекунд, и поллинг мог бы в неё попасть.
      // Здесь мы видим модель напрямую — если пользователь что-то набрал, его текст не трогаем.
      if (isDirty(pane)) {
        post({ t: 'dirty', path: p.path, dirty: true });
        return;
      }

      const isActive = active === p.path;
      const editor = pane.mode === 'diff' ? diffEditor : singleEditor;
      const view = isActive && editor ? editor.saveViewState() : pane.viewState;

      suppressDirty = true;
      if (pane.mode === 'diff' && p.original !== undefined
          && pane.models.original.getValue() !== p.original) {
        pane.models.original.setValue(p.original);
      }
      replaceAll(model, p.modified);
      suppressDirty = false;
      markClean(pane);

      if (isActive && editor && view) editor.restoreViewState(view);
      else pane.viewState = view;

      post({ t: 'dirty', path: p.path, dirty: false });
    },

    closePane(p) {
      const pane = panes.get(p.path);
      if (!pane) return;
      Object.values(pane.models).forEach((m) => m.dispose());
      panes.delete(p.path);
      if (active === p.path) active = null;
    },

    showMessage(p) {
      stashActive();
      active = null;
      elMsg.textContent = p.text;
      showPane('msg');
    },

    setTheme(p) {
      dark = !!p.dark;
      document.body.classList.toggle('light', !dark);
      if (window.monaco) monaco.editor.setTheme(dark ? 'vs-dark' : 'vs');
    },

    setSideBySide(p) {
      sideBySide = !!p.on;
      if (diffEditor) diffEditor.updateOptions({ renderSideBySide: sideBySide });
    },

    openFind() {
      const pane = active && panes.get(active);
      if (!pane) return;
      const editor = pane.mode === 'diff' ? diffEditor.getModifiedEditor() : singleEditor;
      if (editor) { editor.focus(); editor.getAction('actions.find').run(); }
    },

    focusEditor() {
      const pane = active && panes.get(active);
      if (!pane) return;
      const editor = pane.mode === 'diff' ? diffEditor.getModifiedEditor() : singleEditor;
      if (editor) editor.focus();
    },

    setFontSize(p) {
      fontSize = p.size;
      const opts = { fontSize: fontSize, lineHeight: lineHeightFor(fontSize) };
      if (singleEditor) singleEditor.updateOptions(opts);
      if (diffEditor) diffEditor.updateOptions(opts);
    },

    requestSave: doSave,
  };

  window.Remoter = api;

  // --- загрузка Monaco -------------------------------------------------

  // Страница живёт по адресу вида http://127.0.0.1:PORT/<токен>/editor.html, и путь до Monaco
  // обязан быть АБСОЛЮТНЫМ, вместе с токеном.
  //
  // С относительным 'vs' AMD-загрузчик выводит адрес воркера от корня сервера — просит
  // /vs/base/worker/workerMain.js, без токена, получает 404 и молча роняет воркер.
  // А diff Monaco считает как раз в воркере: редактор при этом выглядит совершенно рабочим,
  // подсветка синтаксиса на месте, просто зелёного и красного нет никогда.
  const base = new URL('.', document.baseURI).href; // .../<токен>/

  self.MonacoEnvironment = {
    getWorkerUrl: () => base + 'vs/base/worker/workerMain.js',
  };

  require.config({ paths: { vs: base + 'vs' } });
  require(['vs/editor/editor.main'], function () {
    monaco.editor.setTheme(dark ? 'vs-dark' : 'vs');
    elMsg.textContent = '';
    post({ t: 'ready' });
  });
})();
