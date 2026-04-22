const formEl = document.querySelector("form");

formEl.addEventListener("submit", () => {
  const submitEl = formEl.querySelector("input[type=submit]");
  submitEl.disabled = true;
});
