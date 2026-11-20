function show(enabled, useSettingsInsteadOfPreferences) {
    if (useSettingsInsteadOfPreferences) {
        document.getElementsByClassName('state-on')[0].innerText = "Evening Reader Helper’s extension is currently on. You can turn it off in the Extensions section of Safari Settings.";
        document.getElementsByClassName('state-off')[0].innerText = "Evening Reader Helper’s extension is currently off. You can turn it on in the Extensions section of Safari Settings.";
        document.getElementsByClassName('state-unknown')[0].innerText = "You can turn on Evening Reader Helper’s extension in the Extensions section of Safari Settings.";
        document.getElementsByClassName('open-preferences')[0].innerText = "Quit and Open Safari Settings…";
    }

    if (typeof enabled === "boolean") {
        document.body.classList.toggle(`state-on`, enabled);
        document.body.classList.toggle(`state-off`, !enabled);
    } else {
        document.body.classList.remove(`state-on`);
        document.body.classList.remove(`state-off`);
    }
}

// What opening the app did for Chrome and the other Chromium browsers: "ready", with
// their names; "move", when it was opened from somewhere it won't stay; "failed", with
// why; or "none", when there's no such browser and nothing to say.
function showChrome(state, detail) {
    const section = document.querySelector("section.chrome");
    section.hidden = state === "none";
    section.dataset.state = state;
    document.querySelector(".chrome-browsers").textContent = detail;
    document.querySelector(".chrome-error").textContent = detail;
}

function openPreferences() {
    webkit.messageHandlers.controller.postMessage("open-preferences");
}

function openChromeStore() {
    webkit.messageHandlers.controller.postMessage("open-chrome-store");
}

document.querySelector("button.open-preferences").addEventListener("click", openPreferences);
document.querySelector("button.open-chrome-store").addEventListener("click", openChromeStore);
