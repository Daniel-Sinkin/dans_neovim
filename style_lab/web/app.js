"use strict";

const $ = (selector, root = document) => root.querySelector(selector);
const clone = (id) => document.getElementById(id).content.firstElementChild.cloneNode(true);
let state;
let fitTimer;

function paintRun(run) {
  const span = document.createElement("span");
  span.textContent = run.text;
  const style = run.style || {};
  if (style.fg) span.style.color = style.fg;
  if (style.bg) span.style.backgroundColor = style.bg;
  if (style.bold) span.style.fontWeight = "700";
  if (style.italic) span.style.fontStyle = "italic";
  const decorations = [];
  if (style.underline || style.undercurl) decorations.push("underline");
  if (style.strikethrough) decorations.push("line-through");
  if (decorations.length) span.style.textDecorationLine = decorations.join(" ");
  if (style.undercurl) span.style.textDecorationStyle = "wavy";
  if (style.sp) span.style.textDecorationColor = style.sp;
  return span;
}

function renderCode(target, capture) {
  target.style.backgroundColor = capture.default_colors.bg;
  for (const row of capture.rows) {
    const line = document.createElement("div");
    line.className = "code-row";
    if (!row.runs.length) line.append(document.createTextNode(" "));
    for (const run of row.runs) line.append(paintRun(run));
    target.append(line);
  }
}

// A one- or two-cell overflow should not buy a useless scrollbar. Preserve the
// largest font that fits, down to 80% of the normal size. If the content still
// does not fit there, restore 100% and let the genuinely long line scroll.
function fitCodeFrame(frame) {
  const code = $(".code", frame);
  frame.classList.remove("fitted");
  code.style.fontSize = "";
  const base = Number.parseFloat(getComputedStyle(code).fontSize);
  const fits = () => frame.scrollWidth <= frame.clientWidth + 1;
  if (fits()) return;
  code.style.fontSize = `${base * 0.8}px`;
  if (!fits()) {
    code.style.fontSize = "";
    return;
  }
  let low = 0.8;
  let high = 1;
  for (let iteration = 0; iteration < 8; iteration += 1) {
    const scale = (low + high) / 2;
    code.style.fontSize = `${base * scale}px`;
    if (fits()) low = scale;
    else high = scale;
  }
  code.style.fontSize = `${base * low}px`;
  frame.classList.add("fitted");
}

function scheduleCodeFit() {
  window.clearTimeout(fitTimer);
  fitTimer = window.setTimeout(() => {
    document.querySelectorAll(".code-frame").forEach(fitCodeFrame);
  }, 0);
}

function renderScene(scene, capture) {
  const node = clone("scene-template");
  $("h4", node).textContent = scene.title;
  const provenance = $(".provenance", node);
  provenance.textContent = scene.provenance.label;
  if (scene.provenance.url) provenance.href = scene.provenance.url;
  else provenance.removeAttribute("href");
  renderCode($(".code", node), capture);
  $(".raw-source", node).textContent = scene.lines.join("\n");
  return node;
}

async function saveSelection(question, choiceId, note, indicator) {
  indicator.textContent = "Saving…";
  const response = await fetch("/api/select", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ question_id: question.id, choice_id: choiceId, note }),
  });
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  state.selections = payload.selections;
  renderAll();
  if (payload.complete) {
    // The controlled app-window launcher closes the process as a reliable path;
    // this also closes script-closeable tabs and is harmless when a browser
    // blocks closing an ordinary externally opened tab.
    window.setTimeout(() => window.close(), 120);
  } else {
    indicator.textContent = "Saved";
    window.setTimeout(() => { indicator.textContent = ""; }, 1800);
  }
}

function renderChoice(question, choice, selected, note, indicator) {
  const node = clone("choice-template");
  node.dataset.choiceId = choice.id;
  node.classList.toggle("selected", selected);
  node.setAttribute("aria-checked", String(selected));
  $(".choice-tag", node).textContent = choice.tag;
  $("h3", node).textContent = choice.label;
  $(".choice-head p", node).textContent = choice.summary;
  const scenes = $(".scenes", node);
  for (const scene of question.scenes) {
    const capture = state.renderings[question.id][choice.id][scene.id];
    scenes.append(renderScene(scene, capture));
  }
  const select = () => saveSelection(question, choice.id, note.value, indicator).catch(showError);
  node.addEventListener("click", select);
  node.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      select();
    }
  });
  return node;
}

function renderQuestion(question, index) {
  const node = clone("question-template");
  node.dataset.questionId = question.id;
  $(".question-index", node).textContent = `QUESTION ${String(index + 1).padStart(2, "0")} · ${question.factbase_record}`;
  $("h2", node).textContent = question.title;
  $(".prompt", node).textContent = question.prompt;
  const selected = state.selections.selections[question.id];
  const badge = $(".state-badge", node);
  badge.textContent = selected ? "SELECTED" : "OPEN";
  badge.classList.toggle("selected", Boolean(selected));
  const constraints = $(".constraints", node);
  for (const text of question.constraints) {
    const item = document.createElement("li");
    item.textContent = text;
    constraints.append(item);
  }
  const note = $("textarea", node);
  note.value = selected?.note || "";
  const indicator = $(".save-state", node);
  const choices = $(".choices", node);
  for (const choice of question.choices) {
    choices.append(renderChoice(question, choice, selected?.choice_id === choice.id, note, indicator));
  }
  $(".save-note", node).addEventListener("click", () => {
    if (!selected) {
      indicator.textContent = "Select an option first";
      return;
    }
    saveSelection(question, selected.choice_id, note.value, indicator).catch(showError);
  });
  return node;
}

function renderAll() {
  $("#title").textContent = state.catalog.title;
  $("#description").textContent = state.catalog.description;
  const target = $("#questions");
  target.replaceChildren();
  const openQuestions = state.catalog.questions.filter((q) => q.status === "open");
  openQuestions.forEach((question, index) => target.append(renderQuestion(question, index)));
  const total = openQuestions.length;
  const done = openQuestions.filter((q) => state.selections.selections[q.id]).length;
  $("#progress-label").textContent = `${done} of ${total} decisions recorded`;
  $("#progress-bar").style.width = `${total ? (done / total) * 100 : 100}%`;
  scheduleCodeFit();
}

function showError(error) {
  const node = document.createElement("div");
  node.className = "error";
  node.textContent = error instanceof Error ? error.message : String(error);
  $("#questions").prepend(node);
}

fetch("/api/state")
  .then((response) => {
    if (!response.ok) throw new Error(`Style lab failed to load (${response.status})`);
    return response.json();
  })
  .then((payload) => { state = payload; renderAll(); })
  .catch(showError);

window.addEventListener("resize", scheduleCodeFit, { passive: true });
