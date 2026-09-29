const $ = (selector) => document.querySelector(selector);

const elements = {
  connectionText: $("#connectionText"),
  errorBanner: $("#errorBanner"),
  errorMessage: $("#errorMessage"),
  retryButton: $("#retryButton"),
  refreshButton: $("#refreshButton"),
  advanceButton: $("#advanceButton"),
  advanceButtonText: $("#advanceButtonText"),
  rollbackButton: $("#rollbackButton"),
  actionTitle: $("#actionTitle"),
  actionHint: $("#actionHint"),
  weightValue: $("#weightValue"),
  splitStable: $("#splitStable"),
  splitCanary: $("#splitCanary"),
  stepTrack: $("#stepTrack"),
  routeSummary: $("#routeSummary"),
  revision: $("#revision"),
  policyText: $("#policyText"),
  envoyCheck: $("#envoyCheck"),
  healthCheck: $("#healthCheck"),
  samplesCheck: $("#samplesCheck"),
  errorCheck: $("#errorCheck"),
  eventList: $("#eventList"),
  observedAt: $("#observedAt"),
  confirmDialog: $("#confirmDialog"),
  confirmButton: $("#confirmButton"),
  confirmButtonText: $("#confirmButtonText"),
  dialogTitle: $("#dialogTitle"),
  dialogDescription: $("#dialogDescription"),
  dialogFrom: $("#dialogFrom"),
  dialogTo: $("#dialogTo"),
  toast: $("#toast"),
};

const releaseElements = {
  stable: {
    weight: $("#stableWeight"),
    health: $("#stableHealth"),
    requests: $("#stableRequests"),
    errorRate: $("#stableErrorRate"),
  },
  canary: {
    weight: $("#canaryWeight"),
    health: $("#canaryHealth"),
    requests: $("#canaryRequests"),
    errorRate: $("#canaryErrorRate"),
  },
};

const STATUS_TEXT = {
  idle: "Stable รับ traffic ทั้งหมด · ยังไม่เริ่ม rollout",
  progressing: "Rollout กำลังดำเนินการ",
  promoted: "Canary ได้รับ traffic 100% แล้ว",
  rolled_back: "Rollback แล้ว",
};

const EVENT_LABEL = {
  adopted: "Adopted",
  advanced: "Advanced",
  promoted: "Promoted",
  rollback: "Rollback",
  auto_rollback: "Auto-rollback",
};

let currentState = null;
let isLoading = false;
let pendingAction = null;
let refreshTimer = null;
let toastTimer = null;

const percent = (value) => (value === null || value === undefined ? "—" : `${(value * 100).toFixed(1)}%`);

async function request(path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(path, {
      ...options,
      headers: { Accept: "application/json", ...(options.headers || {}) },
      signal: controller.signal,
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(payload.error || `Request failed with HTTP ${response.status}.`);
    }
    return payload;
  } finally {
    window.clearTimeout(timeout);
  }
}

function setCheck(element, ready, detail) {
  element.classList.toggle("is-ready", ready === true);
  element.classList.toggle("is-failed", ready === false);
  element.querySelector("span:last-child").textContent = detail;
}

function renderRelease(release, state) {
  const view = releaseElements[release];
  const backend = state.backends[release];
  const analysis = state.analysis?.[release];
  const weight = state.weight === null ? null : release === "canary" ? state.weight : 100 - state.weight;

  view.weight.textContent = weight === null ? "—" : `${weight}%`;
  view.health.classList.toggle("is-healthy", backend.healthy);
  view.health.classList.toggle("is-unhealthy", !backend.healthy);
  view.health.querySelector("span:last-child").textContent = backend.healthy
    ? `HTTP ${backend.status_code} · ${backend.latency_ms} ms`
    : "ไม่ผ่าน health probe";
  view.requests.textContent = analysis ? String(analysis.requests) : "—";
  view.errorRate.textContent = analysis ? `${percent(analysis.error_rate)} (${analysis.errors})` : "—";
}

function renderSteps(state) {
  elements.stepTrack.replaceChildren(
    ...state.steps.map((step) => {
      const item = document.createElement("li");
      item.textContent = `${step}%`;
      if (state.weight !== null && step < state.weight) item.className = "is-done";
      if (step === state.weight) {
        item.className = "is-current";
        item.setAttribute("aria-current", "step");
      }
      return item;
    }),
  );
}

function renderEvents(events) {
  if (!events.length) {
    const empty = document.createElement("li");
    empty.className = "event-empty";
    empty.textContent = "ยังไม่มี event";
    elements.eventList.replaceChildren(empty);
    return;
  }
  elements.eventList.replaceChildren(
    ...events.map((event) => {
      const item = document.createElement("li");
      item.dataset.kind = event.kind;
      const kind = document.createElement("strong");
      kind.textContent = EVENT_LABEL[event.kind] || event.kind;
      const message = document.createElement("span");
      message.textContent = event.message;
      const time = document.createElement("time");
      time.dateTime = event.at;
      time.textContent = new Date(event.at).toLocaleTimeString("th-TH");
      item.append(kind, message, time);
      return item;
    }),
  );
}

function render(state) {
  currentState = state;
  const weight = state.weight;
  const gate = state.gate;

  document.body.dataset.connected = String(state.envoy_ready);
  document.body.dataset.active = weight === null ? "unknown" : weight === 0 ? "blue" : weight === 100 ? "green" : "split";
  document.body.dataset.status = state.status;
  elements.connectionText.textContent = state.envoy_ready ? "Envoy connected" : "Envoy unavailable";
  elements.errorBanner.hidden = state.envoy_ready;
  if (state.route_error) elements.errorMessage.textContent = state.route_error;

  elements.weightValue.textContent = weight === null ? "—" : String(weight);
  elements.splitStable.style.flexGrow = String(weight === null ? 1 : 100 - weight);
  elements.splitCanary.style.flexGrow = String(weight === null ? 0 : weight);
  elements.revision.textContent = state.revision || "—";
  renderSteps(state);
  for (const release of ["stable", "canary"]) renderRelease(release, state);

  let summary = STATUS_TEXT[state.status] || state.status;
  if (state.status === "rolled_back" && state.reason) summary = `Rollback แล้ว · ${state.reason}`;
  elements.routeSummary.textContent = weight === null ? "ยังยืนยัน weighted route ไม่ได้" : summary;

  const { max_error_rate: maxErrorRate, min_samples: minSamples } = state.policy;
  elements.policyText.textContent = `Policy: canary ต้องมีอย่างน้อย ${minSamples} requests ต่อขั้น และ 5xx rate ไม่เกิน ${percent(maxErrorRate)} · เกินเมื่อไหร่ controller rollback ให้ทันที`;

  setCheck(elements.envoyCheck, state.envoy_ready, state.envoy_ready ? `Envoy ยอมรับ revision ${state.revision}` : "ติดต่อ Envoy Admin ไม่สำเร็จ");
  if (gate) {
    const canary = state.analysis.canary;
    setCheck(elements.healthCheck, gate.canary_healthy, gate.canary_healthy ? "Canary ตอบ /healthz ปกติ" : "Canary ไม่ผ่าน health probe");
    setCheck(
      elements.samplesCheck,
      gate.enough_samples,
      weight === 0 ? "ขั้นแรกไม่ต้องมี samples" : `${canary.requests} / ${minSamples} requests ที่ ${weight}%`,
    );
    setCheck(
      elements.errorCheck,
      gate.error_rate_ok,
      canary.error_rate === null ? "ยังไม่มี request ไป canary" : `${percent(canary.error_rate)} (limit ${percent(maxErrorRate)})`,
    );
  } else {
    for (const check of [elements.healthCheck, elements.samplesCheck, elements.errorCheck]) setCheck(check, null, "รอข้อมูลจาก Envoy");
  }

  const canAdvance = Boolean(gate?.can_advance) && state.next_step !== null;
  if (weight === null) {
    elements.actionTitle.textContent = "ยังเปลี่ยน traffic ไม่ได้";
    elements.actionHint.textContent = "ตรวจสอบ Envoy และ routes-current.yaml ก่อนดำเนินการ";
    elements.advanceButtonText.textContent = "Route unavailable";
  } else if (weight === 100) {
    elements.actionTitle.textContent = "Rollout เสร็จสมบูรณ์";
    elements.actionHint.textContent = "Canary รับ traffic ทั้งหมด · rollback กลับ 0% ได้ถ้าพบปัญหา";
    elements.advanceButtonText.textContent = "Promoted";
  } else if (canAdvance) {
    elements.actionTitle.textContent = `Gate ผ่าน · พร้อมเพิ่มเป็น ${state.next_step}%`;
    elements.actionHint.textContent = "ต้องยืนยันอีกครั้ง · เปลี่ยน RDS โดยไม่ restart Envoy";
    elements.advanceButtonText.textContent = `Advance to ${state.next_step}%`;
  } else {
    elements.actionTitle.textContent = `ยังเพิ่มเป็น ${state.next_step}% ไม่ได้`;
    elements.actionHint.textContent = gate && !gate.enough_samples
      ? "รอ traffic ไป canary ให้ครบจำนวน samples ก่อน"
      : "Gate ไม่ผ่าน · controller จะ rollback อัตโนมัติถ้า error rate เกิน policy";
    elements.advanceButtonText.textContent = `Advance to ${state.next_step}%`;
  }

  elements.advanceButton.disabled = isLoading || !canAdvance;
  elements.rollbackButton.disabled = isLoading || !weight;

  renderEvents(state.events);
  elements.observedAt.dateTime = state.observed_at;
  elements.observedAt.textContent = new Date(state.observed_at).toLocaleString("th-TH", { dateStyle: "medium", timeStyle: "medium" });
}

function showError(message) {
  document.body.dataset.connected = "false";
  elements.connectionText.textContent = "Console disconnected";
  elements.errorBanner.hidden = false;
  elements.errorMessage.textContent = message;
  elements.advanceButton.disabled = true;
  elements.rollbackButton.disabled = true;
}

function showToast(message, isError = false) {
  window.clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.toggle("is-error", isError);
  elements.toast.hidden = false;
  toastTimer = window.setTimeout(() => {
    elements.toast.hidden = true;
  }, 4500);
}

function setLoading(loading) {
  isLoading = loading;
  elements.refreshButton.disabled = loading;
  elements.advanceButton.classList.toggle("is-loading", loading);
  if (currentState) render(currentState);
}

async function refreshState({ quiet = false } = {}) {
  if (isLoading) return;
  elements.refreshButton.classList.add("is-loading");
  try {
    render(await request("api/state"));
  } catch (error) {
    showError(error.name === "AbortError" ? "การอ่านสถานะใช้เวลานานเกิน 15 วินาที" : error.message);
    if (!quiet) showToast("รีเฟรชสถานะไม่สำเร็จ", true);
  } finally {
    elements.refreshButton.classList.remove("is-loading");
    scheduleRefresh();
  }
}

function scheduleRefresh() {
  window.clearTimeout(refreshTimer);
  if (!document.hidden) {
    refreshTimer = window.setTimeout(() => refreshState({ quiet: true }), 2000);
  }
}

function openConfirmation(action) {
  if (!currentState || currentState.weight === null || isLoading) return;
  pendingAction = action;
  const from = currentState.weight;
  const to = action === "advance" ? currentState.next_step : 0;
  elements.dialogFrom.textContent = `${from}%`;
  elements.dialogTo.textContent = `${to}%`;
  elements.confirmDialog.dataset.action = action;
  if (action === "advance") {
    elements.dialogTitle.textContent = to === 100 ? "Promote canary เป็น 100%?" : `เพิ่ม canary เป็น ${to}%?`;
    elements.dialogDescription.textContent = `Request ใหม่ประมาณ ${to}% จะไป VERSION-2 หลัง Envoy ยอมรับ RDS revision ใหม่`;
    elements.confirmButtonText.textContent = `Advance to ${to}%`;
  } else {
    elements.dialogTitle.textContent = "Rollback canary กลับ 0%?";
    elements.dialogDescription.textContent = "Request ใหม่ทั้งหมดจะกลับไป Stable (VERSION-1) · header x-canary: always ยังใช้ทดสอบ canary ได้";
    elements.confirmButtonText.textContent = "Rollback to 0%";
  }
  elements.confirmDialog.showModal();
}

async function applyRollout() {
  if (!pendingAction || !currentState) return;
  const action = pendingAction;
  pendingAction = null;
  setLoading(true);
  try {
    const state = await request("api/rollout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action, expected_weight: currentState.weight }),
    });
    isLoading = false;
    render(state);
    showToast(action === "advance" ? `Canary weight เป็น ${state.weight}% แล้ว` : "Rollback canary กลับ 0% แล้ว");
  } catch (error) {
    showToast(error.name === "AbortError" ? "Envoy ไม่ยืนยัน route ภายในเวลาที่กำหนด" : error.message, true);
  } finally {
    setLoading(false);
    refreshState({ quiet: true });
  }
}

elements.refreshButton.addEventListener("click", () => refreshState());
elements.retryButton.addEventListener("click", () => refreshState());
elements.advanceButton.addEventListener("click", () => openConfirmation("advance"));
elements.rollbackButton.addEventListener("click", () => openConfirmation("rollback"));
elements.confirmButton.addEventListener("click", () => {
  elements.confirmDialog.close("confirm");
  applyRollout();
});
elements.confirmDialog.addEventListener("close", () => {
  if (elements.confirmDialog.returnValue !== "confirm") pendingAction = null;
});

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    window.clearTimeout(refreshTimer);
  } else {
    refreshState({ quiet: true });
  }
});

refreshState({ quiet: true });
