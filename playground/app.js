import { EditorState } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, defaultHighlightStyle, bracketMatching } from '@codemirror/language';
import { oCaml } from '@codemirror/legacy-modes/mode/mllike';
import { lintGutter, setDiagnostics } from '@codemirror/lint';
import { editorDiagnostics } from './spans.js';

const runButton = document.querySelector('#run');
const status = document.querySelector('#status');
const output = document.querySelector('#output');
const diagnosticsPane = document.querySelector('#diagnostics');
const panels = ['types', 'ir', 'wat'].map(id => document.getElementById(id));
let worker, timer, decoder, frame;
let pending = '';
let edited = false;

function message(text, state = '') { status.textContent = text; status.dataset.state = state; }
function flushOutput() {
  if (frame) cancelAnimationFrame(frame);
  frame = undefined;
  output.textContent += pending;
  pending = '';
}
function stop(text) {
  worker?.terminate();
  worker = undefined;
  clearTimeout(timer);
  if (decoder) pending += decoder.decode();
  decoder = undefined;
  flushOutput();
  runButton.textContent = '▶ Run';
  runButton.classList.remove('running');
  if (text) message(text);
}
function hostError(text) {
  const card = document.createElement('div');
  card.className = 'diagnostic';
  const pre = document.createElement('pre');
  pre.textContent = text;
  card.append(pre);
  diagnosticsPane.append(card);
  message('Stopped with error', 'error');
}
function clearResults() {
  diagnosticsPane.replaceChildren();
  output.textContent = '';
  panels.forEach(panel => { panel.textContent = ''; });
}

const view = new EditorView({
  parent: document.getElementById('editor'),
  state: EditorState.create({
    doc: 'let () = print_string "Hello, Tern!\\n";;',
    extensions: [
      lineNumbers(), highlightActiveLine(), history(), bracketMatching(), lintGutter(),
      StreamLanguage.define(oCaml), syntaxHighlighting(defaultHighlightStyle),
      EditorView.contentAttributes.of({ 'aria-label': 'Tern source', role: 'textbox', 'aria-multiline': 'true', spellcheck: 'false' }),
      keymap.of([{ key: 'Mod-Enter', run: () => { run(); return true; } }, ...defaultKeymap, ...historyKeymap]),
      EditorView.updateListener.of(update => {
        if (!update.docChanged) return;
        edited = true;
        stop();
        clearResults();
        message('Edited · ready to run');
        queueMicrotask(() => view.dispatch(setDiagnostics(view.state, [])));
      }),
    ],
  }),
});

function run() {
  if (worker) { stop('Stopped'); return; }
  clearResults();
  view.dispatch(setDiagnostics(view.state, []));
  const source = view.state.doc.toString();
  decoder = new TextDecoder();
  message('Compiling…');
  runButton.textContent = '■ Stop';
  runButton.classList.add('running');
  try {
    const current = worker = new Worker(new URL('worker.js', document.baseURI));
    timer = setTimeout(() => { stop(); hostError('Run exceeded the 5 second limit.'); }, 5000);
    current.onmessage = ({ data }) => {
      if (worker !== current) return;
      if (data.kind === 'compiled') {
        const result = data.result;
        panels.forEach((panel, i) => { panel.textContent = result[['types', 'ir', 'wat'][i]]; });
        view.dispatch(setDiagnostics(view.state, editorDiagnostics(source, result.diagnostics)));
        for (const diagnostic of result.diagnostics) {
          const card = document.createElement('div');
          card.className = `diagnostic ${diagnostic.severity}`;
          const pre = document.createElement('pre');
          pre.textContent = diagnostic.rendered;
          card.append(pre);
          diagnosticsPane.append(card);
        }
        message(result.ok ? 'Assembling / running…' : 'Compilation failed', result.ok ? '' : 'error');
      } else if (data.kind === 'output') {
        pending += decoder.decode(data.bytes, { stream: true });
        frame ??= requestAnimationFrame(flushOutput);
      } else if (data.kind === 'done') {
        stop();
        if (data.error) hostError(data.error);
        else message(data.success ? 'Completed' : 'Compilation failed', data.success ? 'success' : 'error');
      }
    };
    current.onerror = event => { event.preventDefault(); stop(); hostError(event.message); };
    current.postMessage(source);
  } catch (error) { stop(); hostError(String(error)); }
}
runButton.addEventListener('click', run);

const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(tab) {
  tabs.forEach((item, index) => {
    const active = item === tab;
    item.setAttribute('aria-selected', String(active));
    item.tabIndex = active ? 0 : -1;
    panels[index].hidden = !active;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); selectTab(tabs[next]); tabs[next].focus(); }
  });
});

const exampleSelect = document.getElementById('examples');
fetch('examples.json').then(response => {
  if (!response.ok) throw new Error(`Examples failed to load: HTTP ${response.status}`);
  return response.json();
}).then(examples => {
  for (const example of examples) {
    const option = new Option(example.title, example.file);
    exampleSelect.append(option);
  }
  function loadExample() {
    const example = examples.find(example => example.file === exampleSelect.value);
    if (example) view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: example.source } });
  }
  exampleSelect.addEventListener('change', loadExample);
  if (!edited) {
    exampleSelect.value = examples[0].file;
    loadExample();
  }
}).catch(error => hostError(String(error)));
window.addEventListener('pagehide', () => stop());
