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
