const showUserEls = [...document.querySelectorAll(".data-show-user")];

showUserEls.forEach(showUserEl => {
  showUserEl.addEventListener("click", () => {
    const userID = showUserEl.getAttribute("data-id");
    const panelEl = document.getElementById(userID);

    panelEl.style.display = panelEl.style.display == 'flex' ? 'none' : 'flex';
    showUserEl.innerText = showUserEl.innerText.toLowerCase().startsWith('show') ? 'Hide user' : 'Show user';
  });
});
