(() => {
  "use strict";

  const PASSAGES = {
    zh: [
      "清晨的街道还没有完全醒来，面包店的灯已经亮了。老板把刚出炉的面包整齐地摆在橱窗里，香气顺着门缝飘到路口，让赶早班的人忍不住放慢了脚步。",
      "学习打字最重要的不是速度，而是节奏。手指放在基准键上，眼睛看着屏幕，不要低头找键。坚持每天练习十分钟，一个月后你会发现自己的进步非常明显。",
      "程序员常说，代码是写给人看的，只是顺便能在机器上运行。清晰的命名、简短的函数和必要的注释，能让三个月后的自己少走很多弯路。",
      "傍晚的江边吹着微风，有人在跑步，有人在钓鱼，还有一群孩子追着风筝奔跑。夕阳把水面染成金色，远处的货船慢慢驶过，拖出一道长长的波纹。",
      "一个好的工具应该安静地完成工作，而不是让使用者处处操心。设计软件时，多问一句用户真正想做什么，往往比增加十个新功能更有价值。"
    ],
    en: [
      "The quiet library smelled of old paper and fresh coffee. Students bent over their notebooks while rain tapped softly against the tall windows, and nobody seemed in a hurry to leave.",
      "Good typing is about rhythm rather than raw speed. Keep your fingers on the home row, look at the screen instead of the keyboard, and let accuracy come first. Speed will follow.",
      "A small team shipped their first app after months of late nights. The launch was modest, but every message from a happy user made the long weeks feel worth it.",
      "Mountains look calm from far away, yet the trail to the top is full of loose stones, sharp turns and sudden views that make every tired step feel like a reward.",
      "Write code for the person who will read it next. Clear names, short functions and honest comments save more time than any clever trick ever will."
    ]
  };

  const $ = (id) => document.getElementById(id);
  const els = {
    mode: $("mode"), limit: $("limit"), restart: $("restart"),
    time: $("time"), speed: $("speed"), unit: $("speed-unit"), acc: $("acc"),
    passage: $("passage"), input: $("input"),
    result: $("result"), resultText: $("result-text"),
    form: $("submit-form"), name: $("name"), msg: $("submit-msg"),
    board: $("board"), boardMode: $("board-mode")
  };

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } }
  };

  let chars = [], spans = [], startAt = 0, timer = 0, finished = false;
  let stats = { correct: 0, typed: 0, duration: 0 };
  let lastIndex = -1;

  function pick(mode) {
    const list = PASSAGES[mode];
    let i;
    do { i = Math.floor(Math.random() * list.length); } while (list.length > 1 && i === lastIndex);
    lastIndex = i;
    return list[i];
  }

  function reset(newText) {
    clearInterval(timer);
    const mode = els.mode.value;
    if (newText || chars.length === 0) chars = Array.from(pick(mode));
    els.passage.textContent = "";
    spans = chars.map((c) => {
      const s = document.createElement("span");
      s.textContent = c;
      els.passage.appendChild(s);
      return s;
    });
    if (spans[0]) spans[0].classList.add("cur");
    startAt = 0; finished = false;
    stats = { correct: 0, typed: 0, duration: 0 };
    els.input.value = "";
    els.input.disabled = false;
    els.result.hidden = true;
    els.msg.textContent = "";
    els.time.textContent = els.limit.value;
    els.speed.textContent = "0";
    els.acc.textContent = "100";
    els.unit.textContent = mode === "en" ? "WPM" : "CPM";
    els.input.focus();
  }

  function elapsed() { return startAt ? (performance.now() - startAt) / 1000 : 0; }

  function speedOf(correct, seconds) {
    if (seconds <= 0) return 0;
    const perMin = correct / (seconds / 60);
    return els.mode.value === "en" ? perMin / 5 : perMin;
  }

  function update() {
    if (finished) return;
    const typed = Array.from(els.input.value);
    if (typed.length > chars.length) {
      typed.length = chars.length;
      els.input.value = typed.join("");
    }
    if (!startAt && typed.length > 0) {
      startAt = performance.now();
      timer = setInterval(tick, 200);
    }
    let correct = 0;
    for (let i = 0; i < spans.length; i++) {
      const s = spans[i];
      s.className = "";
      if (i < typed.length) {
        if (typed[i] === chars[i]) { s.classList.add("ok"); correct++; }
        else s.classList.add("bad");
      } else if (i === typed.length) s.classList.add("cur");
    }
    stats.correct = correct;
    stats.typed = typed.length;
    els.acc.textContent = typed.length ? Math.round((correct / typed.length) * 100) : 100;
    if (typed.length === chars.length) finish();
  }

  function tick() {
    const left = Number(els.limit.value) - elapsed();
    els.time.textContent = Math.max(0, Math.ceil(left));
    // Skip the first two seconds: dividing by a tiny elapsed time gives huge spikes.
    if (elapsed() >= 2) els.speed.textContent = Math.round(speedOf(stats.correct, elapsed()));
    if (left <= 0) finish();
  }

  function finish() {
    if (finished) return;
    finished = true;
    clearInterval(timer);
    stats.duration = Math.min(elapsed(), Number(els.limit.value));
    els.input.disabled = true;
    els.time.textContent = Math.max(0, Math.ceil(Number(els.limit.value) - stats.duration));
    const sp = speedOf(stats.correct, stats.duration);
    const acc = stats.typed ? (stats.correct / stats.typed) * 100 : 0;
    els.speed.textContent = Math.round(sp);
    els.resultText.textContent =
      `速度 ${sp.toFixed(1)} ${els.unit.textContent} · 准确率 ${acc.toFixed(1)}% · ` +
      `用时 ${stats.duration.toFixed(1)} 秒 · 正确 ${stats.correct} 字`;
    const canSubmit = stats.duration >= 10 && stats.correct >= 10;
    els.form.hidden = !canSubmit;
    if (!canSubmit) els.msg.textContent = "用时少于 10 秒或正确字数不足 10，本次成绩不能上榜。";
    els.result.hidden = false;
    els.name.value = store.get("typer-name") || "";
  }

  async function submit(e) {
    e.preventDefault();
    const name = els.name.value.trim();
    if (!name) return;
    store.set("typer-name", name);
    els.form.hidden = true;
    els.msg.textContent = "提交中…";
    try {
      const res = await fetch("/api/scores", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name, mode: els.mode.value,
          correct: stats.correct, typed: stats.typed,
          duration: Math.round(stats.duration * 100) / 100
        })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "提交失败");
      els.msg.textContent = data.rank ? `已上榜，当前第 ${data.rank} 名！` : "已提交，但这次没进前 100，再接再厉！";
      loadBoard();
    } catch (err) {
      els.msg.textContent = err.message;
      els.form.hidden = false;
    }
  }

  async function loadBoard() {
    const mode = els.mode.value;
    const unit = mode === "en" ? "WPM" : "CPM";
    els.boardMode.textContent = mode === "en" ? "English" : "中文";
    try {
      const res = await fetch(`/api/scores?mode=${mode}`);
      const list = await res.json();
      els.board.textContent = "";
      if (!list.length) {
        const tr = els.board.insertRow();
        const td = tr.insertCell();
        td.colSpan = 5;
        td.textContent = "还没有成绩，来当第一名吧！";
        return;
      }
      list.forEach((s, i) => {
        const tr = els.board.insertRow();
        [i + 1, s.name, `${s.speed} ${unit}`, `${s.accuracy}%`, `${s.duration}s`]
          .forEach((v) => { tr.insertCell().textContent = v; });
      });
    } catch {
      els.board.textContent = "";
      els.board.insertRow().insertCell().textContent = "排行榜加载失败";
    }
  }

  els.input.addEventListener("input", (e) => { if (!e.isComposing) update(); });
  els.input.addEventListener("compositionend", update);
  els.input.addEventListener("paste", (e) => e.preventDefault());
  els.restart.addEventListener("click", () => reset(true));
  els.mode.addEventListener("change", () => { store.set("typer-mode", els.mode.value); reset(true); loadBoard(); });
  els.limit.addEventListener("change", () => reset(false));
  els.form.addEventListener("submit", submit);

  const saved = store.get("typer-mode");
  if (saved === "en" || saved === "zh") els.mode.value = saved;
  reset(true);
  loadBoard();
})();
