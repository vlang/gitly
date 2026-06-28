function post(url, dataObj, success) {
	// Create a FormData object
	const formData = new FormData();

	console.log(dataObj);
	if (dataObj !== undefined) {
		// Populate the FormData object with the object entries
		Object.entries(dataObj).forEach(([key, value]) => {
			formData.append(key, value);
		});
	}

	// Send the POST request with the FormData object
	fetch(url, {
		method: "POST",
		body: formData,
	})
		.then((response) => {
			/*
			if (!response.ok) {
				throw new Error("Network response was not ok");
			}
			*/
			return response.json(); // or .text() if the response is not in JSON format
		})
		.then((data) => {
			if (success !== undefined) {
				//const json_data = JSON.parse(data);
				success(data);
				//success(json_data);
			}
			//console.log("Success:", data);
		})
		.catch((error) => {
			console.error("Error:", error);
		});
}


function change_lang(x) {
	var y = document.getElementById("select_lang");
	post('/change_lang/' + y.value, {}, () => {
		window.location.reload();
	}	 )
}

function initPrFilesTree() {
	const input = document.querySelector("[data-pr-files-filter]");
	const tree = document.querySelector("[data-pr-files-tree]");
	if (!input || !tree) {
		return;
	}

	const clearButton = document.querySelector("[data-pr-files-filter-clear]");
	const countEl = document.querySelector("[data-pr-files-count]");
	const emptyEl = document.querySelector("[data-pr-files-filter-empty]");
	const rows = Array.from(tree.querySelectorAll(".r, [data-pr-tree-row]"));
	const fileRows = rows.filter((row) => row.hasAttribute("p") || row.hasAttribute("data-file-path"));
	const diffEls = Array.from(document.querySelectorAll("[data-diff-path]"));
	const totalFiles = fileRows.length;
	const collapsedDirs = new Set();

	function pathForRow(row) {
		return row.getAttribute("p") || row.getAttribute("q") || row.getAttribute("data-file-path") || row.getAttribute("data-dir-path") || "";
	}

	function addParentDirs(path, visibleDirs) {
		const parts = path.split("/");
		let current = "";
		for (let i = 0; i < parts.length - 1; i++) {
			current = current === "" ? parts[i] : current + "/" + parts[i];
			visibleDirs.add(current);
		}
	}

	function isUnderCollapsed(path) {
		for (const dir of collapsedDirs) {
			if (path !== dir && path.indexOf(dir + "/") === 0) {
				return true;
			}
		}
		return false;
	}

	function applyPrFilesFilter() {
		const query = input.value.trim().toLowerCase();
		const visibleDirs = new Set();
		let visibleFileCount = 0;

		for (const row of fileRows) {
			const path = row.getAttribute("p") || row.getAttribute("data-file-path") || "";
			if (query === "" || path.toLowerCase().indexOf(query) !== -1) {
				visibleFileCount++;
				addParentDirs(path, visibleDirs);
			}
		}

		for (const row of rows) {
			const filePath = row.getAttribute("p") || row.getAttribute("data-file-path");
			const dirPath = row.getAttribute("q") || row.getAttribute("data-dir-path");
			let visible = true;

			if (filePath) {
				visible = query === "" || filePath.toLowerCase().indexOf(query) !== -1;
			} else if (dirPath) {
				visible = query === "" || visibleDirs.has(dirPath);
			}

			if (visible && query === "" && isUnderCollapsed(pathForRow(row))) {
				visible = false;
			}
			row.hidden = !visible;
		}

		for (const diffEl of diffEls) {
			const path = diffEl.getAttribute("data-diff-path") || "";
			diffEl.hidden = query !== "" && path.toLowerCase().indexOf(query) === -1;
		}

		if (countEl) {
			countEl.textContent = query === "" ? String(totalFiles) : visibleFileCount + " / " + totalFiles;
		}
		if (emptyEl) {
			emptyEl.hidden = query === "" || visibleFileCount > 0;
		}
		if (clearButton) {
			clearButton.hidden = input.value === "";
		}
	}

	for (const row of rows) {
		if (!row.hasAttribute("q") && !row.hasAttribute("data-dir-path")) {
			continue;
		}
		row.addEventListener("click", () => {
			const path = row.getAttribute("q") || row.getAttribute("data-dir-path");
			if (!path) {
				return;
			}
			if (collapsedDirs.has(path)) {
				collapsedDirs.delete(path);
				row.setAttribute("aria-expanded", "true");
			} else {
				collapsedDirs.add(path);
				row.setAttribute("aria-expanded", "false");
			}
			applyPrFilesFilter();
		});
	}

	input.addEventListener("input", applyPrFilesFilter);
	input.addEventListener("keydown", (event) => {
		if (event.key === "Enter") {
			event.preventDefault();
		}
	});

	if (clearButton) {
		clearButton.addEventListener("click", () => {
			input.value = "";
			input.focus();
			applyPrFilesFilter();
		});
	}

	applyPrFilesFilter();
}

function initPrReviewCommentBoxes() {
	const root = document.querySelector(".pr-files-diffs");
	if (!root) {
		return;
	}
	const placeholder = root.getAttribute("data-line-comment-placeholder") || "";

	function ensureBox(row) {
		if (!row || !row.hasAttribute("s") || !row.hasAttribute("l")) {
			return null;
		}
		const next = row.nextElementSibling;
		if (next && next.classList.contains("m")) {
			return next;
		}
		const diff = row.closest("[data-diff-path]");
		const path = diff ? diff.getAttribute("data-diff-path") : "";
		const side = row.getAttribute("s") === "n" ? "new" : "old";
		const line = row.getAttribute("l") || "";
		if (!path || !line) {
			return null;
		}
		const wrap = document.createElement("p");
		wrap.className = "m";
		const textarea = document.createElement("textarea");
		textarea.name = "rc::" + path + "::" + side + "::" + line;
		textarea.rows = 2;
		if (placeholder) {
			textarea.placeholder = placeholder;
		}
		wrap.appendChild(textarea);
		row.insertAdjacentElement("afterend", wrap);
		return wrap;
	}

	function rowFromEvent(event) {
		const target = event.target instanceof Element ? event.target : null;
		return target ? target.closest(".pr-diff__table > p[s][l]") : null;
	}

	root.addEventListener("mouseover", (event) => {
		ensureBox(rowFromEvent(event));
	});
	root.addEventListener("focusin", (event) => {
		ensureBox(rowFromEvent(event));
	});
	root.addEventListener("click", (event) => {
		const box = ensureBox(rowFromEvent(event));
		const textarea = box ? box.querySelector("textarea") : null;
		if (textarea) {
			textarea.focus();
		}
	});
}

document.addEventListener("DOMContentLoaded", () => {
	initPrFilesTree();
	initPrReviewCommentBoxes();
});
