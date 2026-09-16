const $ = (id) => document.getElementById(id);
let resumePath = "";
let profileId = "current";
let activeJob = "";
let pollTimer = null;

function setStatus(el, text, kind = "muted") {
  el.textContent = text;
  el.className = `status ${kind}`;
}

function currentProfile() {
  const raw = $("profile").value.trim();
  if (!raw) throw new Error("Parse a CV or paste profile JSON first.");
  return JSON.parse(raw);
}

$("provider").addEventListener("change", () => {
  if ($("provider").value === "openai") $("model").value = window.FORM_DEFAULTS.openai_model;
  if ($("provider").value === "ollama") $("model").value = window.FORM_DEFAULTS.ollama_model;
  if ($("provider").value === "none") $("model").value = "";
});

$("cvForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.currentTarget.querySelector("button[type=submit]");
  button.disabled = true;
  setStatus($("parseStatus"), "Parsing CV…");
  try {
    const body = new FormData(event.currentTarget);
    const response = await fetch("api/cv/parse", { method: "POST", body });
    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "CV parsing failed");
    $("profile").value = JSON.stringify(data.profile, null, 2);
    resumePath = data.resume_path || "";
    profileId = data.profile_id || "current";
    setStatus($("parseStatus"), `Parsed ${data.resume_name} using ${data.provider}.`, "success");
    setStatus($("profileStatus"), "Profile ready; edit anything before autofill.", "success");
  } catch (error) {
    setStatus($("parseStatus"), error.message, "error");
  } finally {
    button.disabled = false;
  }
});

$("saveProfile").addEventListener("click", async () => {
  try {
    const profile = currentProfile();
    const response = await fetch("api/profile/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ profile_id: profileId, profile }),
    });
    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Save failed");
    setStatus($("profileStatus"), "Profile saved.", "success");
  } catch (error) {
    setStatus($("profileStatus"), error.message, "error");
  }
});

async function pollJob() {
  if (!activeJob) return;
  try {
    const response = await fetch(`api/jobs/${activeJob}`);
    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Status failed");
    const kind = data.state === "failed" ? "error" : (data.state === "review" ? "success" : "muted");
    setStatus($("runStatus"), `${data.state}: ${data.message}`, kind);
    $("runLog").textContent = data.log || "";
    $("runLog").scrollTop = $("runLog").scrollHeight;
    if (data.has_screenshot) {
      $("screenshotLink").href = `api/jobs/${activeJob}/screenshot?t=${Date.now()}`;
      $("screenshotLink").classList.remove("hidden");
    }
    if (data.state === "failed" || data.state === "review") {
      clearInterval(pollTimer);
      pollTimer = null;
      $("autofill").disabled = false;
    }
  } catch (error) {
    setStatus($("runStatus"), error.message, "error");
  }
}

$("autofill").addEventListener("click", async () => {
  const button = $("autofill");
  button.disabled = true;
  $("screenshotLink").classList.add("hidden");
  $("runLog").textContent = "";
  try {
    const profile = currentProfile();
    const jobUrl = $("jobUrl").value.trim();
    const response = await fetch("api/autofill", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        job_url: jobUrl,
        profile,
        resume_path: resumePath,
        browser: $("browser").value,
        headless: $("headless").checked,
        auto_advance: $("autoAdvance").checked,
      }),
    });
    const data = await response.json();
    if (!data.ok) throw new Error(data.error || "Could not start autofill");
    activeJob = data.job_id;
    setStatus($("runStatus"), `queued: ${activeJob}`);
    pollTimer = setInterval(pollJob, 1500);
    pollJob();
  } catch (error) {
    setStatus($("runStatus"), error.message, "error");
    button.disabled = false;
  }
});
