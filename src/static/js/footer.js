const errorEl = document.querySelector(".form-error");

if (errorEl) {
  const errorMessage = errorEl.textContent.trim();
  const isEmpty = errorMessage === "";

  if (!isEmpty) {
    errorEl.classList.add("alert");

    errorEl.addEventListener("click", () => {
      errorEl.style.display = "none";
    });
  }
}
