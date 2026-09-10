const elements = {
  connection: document.querySelector("#connection"),
  connectionText: document.querySelector("#connectionText"),
  errorBanner: document.querySelector("#errorBanner"),
  errorMessage: document.querySelector("#errorMessage"),
  retryButton: document.querySelector("#retryButton"),
  refreshButton: document.querySelector("#refreshButton"),
  switchButton: document.querySelector("#switchButton"),
  switchButtonText: document.querySelector("#switchButtonText"),
  actionTitle: document.querySelector("#actionTitle"),
  actionHint: document.querySelector("#actionHint"),
  routeSummary: document.querySelector("#routeSummary"),
  revision: document.querySelector("#revision"),
  observedAt: document.querySelector("#observedAt"),
  envoyCheck: document.querySelector("#envoyCheck"),
  candidateCheck: document.querySelector("#candidateCheck"),
  confirmDialog: document.querySelector("#confirmDialog"),
  confirmButton: document.querySelector("#confirmButton"),
  confirmButtonText: document.querySelector("#confirmButtonText"),
  dialogTitle: document.querySelector("#dialogTitle"),
  dialogDescription: document.querySelector("#dialogDescription"),
  dialogFrom: document.querySelector("#dialogFrom"),
  dialogTo: document.querySelector("#dialogTo"),
  toast: document.querySelector("#toast"),
};

const slotElements = {
  blue: {
    active: document.querySelector("#blueActive"),
    health: document.querySelector("#blueHealth"),
    probe: document.querySelector("#blueProbe"),
  },
  green: {
    active: document.querySelector("#greenActive"),
    health: document.querySelector("#greenHealth"),
    probe: document.querySelector("#greenProbe"),
  },
};

let currentState = null;
let isLoading = false;
let pendingTarget = null;
let refreshTimer = null;
let toastTimer = null;

function slotName(slot) {
  return slot === "blue" ? "Blue" : "Green";
}

async function request(path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(path, {
      ...options,
      headers: {
        Accept: "application/json",
        ...(options.headers || {}),
      },
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
  element.classList.toggle("is-ready", Boolean(ready));
  element.classList.toggle("is-failed", ready === false);
  element.querySelector("span:last-child").textContent = detail;
}

function renderBackend(slot, backend) {
  const view = slotElements[slot];
  view.health.classList.toggle("is-healthy", backend.healthy);
  view.health.classList.toggle("is-unhealthy", !backend.healthy);
  view.health.querySelector("span:last-child").textContent = backend.healthy ? "พร้อมรับ Traffic" : "ไม่พร้อม";

  const status = backend.status_code ? `HTTP ${backend.status_code}` : "No response";
  view.probe.textContent = `${status} · ${backend.latency_ms} ms`;
}

function render(state) {
  currentState = state;
  const active = state.active;
  const candidate = active === "blue" ? "green" : active === "green" ? "blue" : null;
  const candidateHealth = candidate ? state.backends[candidate] : null;

  document.body.dataset.connected = String(state.envoy_ready);
  document.body.dataset.active = active || "unknown";
  elements.connectionText.textContent = state.envoy_ready ? "Envoy connected" : "Envoy unavailable";
  elements.errorBanner.hidden = state.envoy_ready;
  if (state.route_error) {
    elements.errorMessage.textContent = state.route_error;
  }

  for (const slot of ["blue", "green"]) {
    slotElements[slot].active.textContent = active === slot ? "Active" : "Standby";
    renderBackend(slot, state.backends[slot]);
  }

  if (active) {
    elements.routeSummary.textContent = `${slotName(active)} กำลังรับ Production Traffic`;
    elements.revision.textContent = state.revision || "unknown";
  } else {
    elements.routeSummary.textContent = "ยังยืนยัน Active Route ไม่ได้";
    elements.revision.textContent = "—";
  }

  setCheck(
    elements.envoyCheck,
    state.envoy_ready,
    state.envoy_ready ? `อ่าน dynamic_route revision ${state.revision}` : "ติดต่อ Envoy Admin ไม่สำเร็จ",
  );

  if (candidate) {
    setCheck(
      elements.candidateCheck,
      candidateHealth.healthy,
      candidateHealth.healthy
        ? `${slotName(candidate)} ตอบ HTTP ${candidateHealth.status_code} ภายใน ${candidateHealth.latency_ms} ms`
        : `${slotName(candidate)} ไม่ผ่าน health probe`,
    );
  } else {
    setCheck(elements.candidateCheck, null, "รอ active route ก่อนเลือก candidate");
  }

  elements.observedAt.dateTime = state.observed_at;
  elements.observedAt.textContent = new Date(state.observed_at).toLocaleString("th-TH", {
    dateStyle: "medium",
    timeStyle: "medium",
  });

  if (!active) {
    elements.actionTitle.textContent = "ยังเปลี่ยน Traffic ไม่ได้";
    elements.actionHint.textContent = "ตรวจสอบ Envoy และ routes-current.yaml ก่อนดำเนินการ";
    elements.switchButtonText.textContent = "Route unavailable";
  } else if (!candidateHealth.healthy) {
    elements.actionTitle.textContent = `${slotName(candidate)} ยังไม่พร้อม`;
    elements.actionHint.textContent = "Health check ยังไม่ผ่าน · Controller จะไม่เปลี่ยน RDS";
    elements.switchButtonText.textContent = active === "blue" ? "Promote Green" : "Rollback to Blue";
  } else if (active === "blue") {
    elements.actionTitle.textContent = "3/3 Checks Passed · Green พร้อม Promote";
    elements.actionHint.textContent = "ต้องยืนยันอีกครั้ง · เปลี่ยนโดยไม่ restart · rollback ได้ทันที";
    elements.switchButtonText.textContent = "Promote Green";
  } else {
    elements.actionTitle.textContent = "3/3 Checks Passed · Blue พร้อม Rollback";
    elements.actionHint.textContent = "ต้องยืนยันอีกครั้ง · เปลี่ยนโดยไม่ restart · Green ยัง Standby";
    elements.switchButtonText.textContent = "Rollback to Blue";
  }

  elements.switchButton.disabled = isLoading || !active || !candidateHealth?.healthy;
}

function showError(message) {
  document.body.dataset.connected = "false";
  elements.connectionText.textContent = "Console disconnected";
  elements.errorBanner.hidden = false;
  elements.errorMessage.textContent = message;
  elements.switchButton.disabled = true;
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
  elements.refreshButton.classList.toggle("is-loading", loading);
  elements.switchButton.classList.toggle("is-loading", loading);
  if (currentState) {
    render(currentState);
  }
}

async function refreshState({ quiet = false } = {}) {
  if (isLoading) return;
  elements.refreshButton.classList.add("is-loading");
  try {
    const state = await request("api/state");
    render(state);
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
    refreshTimer = window.setTimeout(() => refreshState({ quiet: true }), 5000);
  }
}

function openConfirmation() {
  if (!currentState?.active || isLoading) return;
  pendingTarget = currentState.active === "blue" ? "green" : "blue";
  const from = slotName(currentState.active);
  const to = slotName(pendingTarget);

  elements.dialogFrom.textContent = from;
  elements.dialogTo.textContent = to;
  elements.dialogTitle.textContent = pendingTarget === "green" ? "Promote Green เป็น Production?" : "Rollback Traffic กลับ Blue?";
  elements.dialogDescription.textContent = `Request ใหม่ 100% จะเปลี่ยนจาก ${from} ไป ${to} หลัง Envoy ยอมรับ RDS revision ใหม่`;
  elements.confirmButtonText.textContent = pendingTarget === "green" ? "สลับ Production Traffic ไป Green" : "สลับ Production Traffic กลับ Blue";
  elements.confirmDialog.showModal();
}

async function switchTraffic() {
  if (!pendingTarget || !currentState?.active) return;
  const expectedActive = currentState.active;
  const target = pendingTarget;
  pendingTarget = null;
  setLoading(true);
  elements.switchButtonText.textContent = "กำลังยืนยัน RDS";

  try {
    const state = await request("api/switch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ target, expected_active: expectedActive }),
    });
    render(state);
    showToast(`เปลี่ยน Production Traffic ไป ${slotName(target)} แล้ว`);
  } catch (error) {
    showToast(error.name === "AbortError" ? "Envoy ไม่ยืนยัน route ภายในเวลาที่กำหนด" : error.message, true);
    await refreshState({ quiet: true });
  } finally {
    setLoading(false);
  }
}

elements.refreshButton.addEventListener("click", () => refreshState());
elements.retryButton.addEventListener("click", () => refreshState());
elements.switchButton.addEventListener("click", openConfirmation);
elements.confirmButton.addEventListener("click", () => {
  elements.confirmDialog.close("confirm");
  switchTraffic();
});
elements.confirmDialog.addEventListener("close", () => {
  if (elements.confirmDialog.returnValue !== "confirm") pendingTarget = null;
});

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    window.clearTimeout(refreshTimer);
  } else {
    refreshState({ quiet: true });
  }
});

refreshState({ quiet: true });
