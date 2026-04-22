const removeEls = document.querySelectorAll(".ssh-key-remove");

[...removeEls].forEach(el => {
  el.addEventListener("click", () => {
    const title = el.dataset.title;

    if (confirm("Do you really want to remove \"" + title + "\"?")) {
      removeSSHKey(el.dataset.username, el.dataset.id)
        .then(() => location.reload())
        .catch(error => alert(error));
    }
  });
});

async function removeSSHKey(username, id) {
  await fetch(`/${username}/settings/ssh-keys/${id}`, {
    method: "DELETE"
  });
}
