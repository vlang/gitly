const branchSelectEl = document.querySelector(".branch-select");
branchSelectEl.addEventListener("change", (event) => {
  window.location.href = TREE_BRANCH_PATH_TEMPLATE + event.target.value;
});

branchSelectEl.value = BRANCH_NAME;

// Make the entire row clickable
const fileEls = document.querySelectorAll(".file");

fileEls.forEach(fileEl => {
  fileEl.addEventListener("click", () => {
    window.location = fileEl.querySelector("a").href;
  });
});

const starButtonEl = document.querySelector(".star-button");

async function starRepo(repoId) {
  const url = "/api/v1/repos/" + repoId + "/star";
  const response = await fetch(url, {
    method: "POST"
  });
  const json = await response.json();

  if (json.success) {
    return json.result === "true";
  } else {
    throw new Error(json.message);
  }
}

starButtonEl.addEventListener("click", () => {
  starRepo(REPO_ID)
    .then(() => {
      location.reload()
    })
    .catch((error) => {
      alert(error.toString());
    })
});

const copyCloneURLButton = document.querySelector(".copy-clone-url-button");
copyCloneURLButton.addEventListener("click", async () => {
  const url = document.querySelector(".clone-input-group > input").value;

  if (navigator && navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(url);
  }

  alert("The Clipboard API is not available.");
});

const watchButtonEl = document.querySelector(".watch-button");

async function watchRepo(repoId) {
  const url = "/api/v1/repos/" + repoId + "/watch";
  const response = await fetch(url, {
    method: "POST"
  });
  const json = await response.json();

  if (json.success) {
    return json.result;
  } else {
    throw new Error(json.message);
  }
}

watchButtonEl.addEventListener("click", () => {
  watchRepo(REPO_ID)
    .then(() => {
      location.reload()
    })
    .catch((error) => {
      alert(error.toString());
    })
});

// Poll for file commit info (last_msg, last_hash, last_time) that may still be loading
(function() {
  // Check if any file rows are missing commit info
  function hasMissingInfo() {
    const msgEls = document.querySelectorAll("[data-msg-for]");
    for (const el of msgEls) {
      const link = el.querySelector("a");
      if (!link || link.textContent.trim() === "") return true;
    }
    return false;
  }

  if (!hasMissingInfo()) return;

  const path = typeof CURRENT_PATH !== "undefined" ? CURRENT_PATH : "";
  const apiUrl = "/api/v1/repos/" + REPO_ID + "/files?branch=" +
    encodeURIComponent(BRANCH_NAME) + "&path=" + encodeURIComponent(path);

  let attempts = 0;
  const maxAttempts = 30;

  function poll() {
    attempts++;
    fetch(apiUrl)
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (!data.success || !data.result) return;

        let stillMissing = false;
        for (const file of data.result) {
          if (!file.last_msg) {
            stillMissing = true;
            continue;
          }
          const msgEl = document.querySelector('[data-msg-for="' + file.name + '"]');
          if (msgEl) {
            const link = msgEl.querySelector("a");
            if (link && link.textContent.trim() === "") {
              link.textContent = file.last_msg;
              if (file.last_hash) {
                link.href = "/" + REPO_USER + "/" + REPO_NAME + "/commit/" + file.last_hash;
              }
            }
          }
          const timeEl = document.querySelector('[data-time-for="' + file.name + '"]');
          if (timeEl && timeEl.textContent.trim() === "" && file.last_time) {
            timeEl.textContent = file.last_time;
          }
        }

        if (stillMissing && attempts < maxAttempts) {
          setTimeout(poll, 2000);
        }
      })
      .catch(function() {
        if (attempts < maxAttempts) {
          setTimeout(poll, 2000);
        }
      });
  }

  // Start polling after a short delay to give the background task time to begin
  setTimeout(poll, 1000);
})();
