(() => {
  const root = document.getElementById("loc-history");
  if (!root) return;
  const status = document.getElementById("loc-status");
  const progress = document.getElementById("loc-progress");
  const form = document.getElementById("loc-start-form");
  const button = document.getElementById("loc-start-button");
  const chart = document.getElementById("loc-chart");
  const svg = document.getElementById("loc-svg");
  const hover = document.getElementById("loc-hover");
  const legend = document.getElementById("loc-legend");
  const ns = "http://www.w3.org/2000/svg";
  const number = new Intl.NumberFormat();
  let lastDrawn = "";

  function element(tag, attributes = {}) {
    const node = document.createElementNS(ns, tag);
    for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, String(value));
    return node;
  }

  function render(data) {
    const snapshots = data.snapshots;
    const languageRows = data.languages;
    const bySnapshot = new Map(snapshots.map(snapshot => [snapshot.id, new Map()]));
    for (const row of languageRows) {
      const counts = bySnapshot.get(row.snapshot_id);
      if (!counts) continue;
      const name = row.name === "C Header" ? "C" : row.name;
      counts.set(name, (counts.get(name) || 0) + row.code);
    }

    svg.replaceChildren();
    legend.replaceChildren();
    if (!snapshots.length) {
      hover.textContent = "No snapshots were saved.";
      return;
    }
    const latestCounts = bySnapshot.get(snapshots.at(-1).id);
    const names = [...latestCounts.entries()]
      .filter(([, code]) => code > 0)
      .sort(([a, aCode], [b, bCode]) => bCode - aCode || a.localeCompare(b))
      .slice(0, 4)
      .map(([name]) => name);
    const colors = new Map(names.map((name, index) => [name, `hsl(${Math.round((index * 137.508 + 215) % 360)} 62% 46%)`]));
    const shownTotals = snapshots.map(snapshot => names.reduce((sum, name) => sum + (bySnapshot.get(snapshot.id).get(name) || 0), 0));
    const width = 920, height = 310, left = 72, right = 12, top = 14, bottom = 38;
    const plotWidth = width - left - right, plotHeight = height - top - bottom;
    const max = Math.max(1, ...shownTotals);
    const x = index => left + (snapshots.length === 1 ? plotWidth / 2 : index * plotWidth / (snapshots.length - 1));
    const y = count => top + plotHeight * (1 - count / max);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

    for (let i = 0; i <= 4; i++) {
      const count = max * i / 4, py = y(count);
      svg.append(element("line", { x1: left, x2: width - right, y1: py, y2: py, class: "loc-grid" }));
      const label = element("text", { x: left - 8, y: py + 4, "text-anchor": "end", class: "loc-axis-label" });
      label.textContent = number.format(Math.round(count));
      svg.append(label);
    }
    const first = new Date(snapshots[0].week_start * 1000).toLocaleDateString();
    const last = new Date(snapshots.at(-1).week_start * 1000).toLocaleDateString();
    for (const [position, labelText] of [[left, first], [width - right, last]]) {
      const label = element("text", { x: position, y: height - 7, "text-anchor": position === left ? "start" : "end", class: "loc-axis-label" });
      label.textContent = labelText;
      svg.append(label);
    }

    const baseline = snapshots.map(() => 0);
    for (const name of names) {
      const values = snapshots.map((snapshot, index) => baseline[index] + (bySnapshot.get(snapshot.id).get(name) || 0));
      if (snapshots.length === 1) {
        svg.append(element("rect", { x: x(0) - 18, y: y(values[0]), width: 36, height: Math.max(0, y(baseline[0]) - y(values[0])), fill: colors.get(name), class: "loc-area" }));
      } else {
        const upper = values.map((value, index) => `${x(index)},${y(value)}`);
        const lower = baseline.map((value, index) => `${x(index)},${y(value)}`).reverse();
        svg.append(element("polygon", { points: [...upper, ...lower].join(" "), fill: colors.get(name), class: "loc-area" }));
      }
      values.forEach((value, index) => baseline[index] = value);
      const item = document.createElement("span"), swatch = document.createElement("i");
      swatch.style.backgroundColor = colors.get(name);
      item.append(swatch, document.createTextNode(name));
      legend.append(item);
    }

    snapshots.forEach((snapshot, index) => {
      const interval = plotWidth / Math.max(1, snapshots.length - 1);
      const hit = element("rect", { x: Math.max(left, x(index) - interval / 2), y: top, width: Math.min(interval, width - right - Math.max(left, x(index) - interval / 2)), height: plotHeight, class: "loc-hit", tabindex: "0" });
      const date = new Date(snapshot.week_start * 1000).toLocaleDateString();
      const details = names.map(name => `${name}: ${number.format(bySnapshot.get(snapshot.id).get(name) || 0)}`).filter(value => !value.endsWith(": 0"));
      const label = `${date} · ${number.format(shownTotals[index])} LOC in shown languages${details.length ? " · " + details.join(" · ") : ""}`;
      hit.setAttribute("aria-label", label);
      hit.addEventListener("mouseenter", () => hover.textContent = label);
      hit.addEventListener("focus", () => hover.textContent = label);
      svg.append(hit);
    });
    hover.textContent = `${number.format(snapshots.length)} weekly snapshots · ${number.format(shownTotals.at(-1))} LOC across ${names.length} shown languages in the latest snapshot`;
  }

  async function refresh() {
    try {
      const response = await fetch(root.dataset.url, { cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const job = data.job;
      const active = job.status === "queued" || job.status === "running";
      progress.hidden = !active;
      progress.value = job.total ? 100 * job.completed / job.total : 0;
      if (form) {
        form.hidden = active;
        button.textContent = job.status === "done" ? "Reanalyze history" : job.status === "failed" ? "Retry analysis" : "Analyze history";
      }
      if (job.status === "queued") status.textContent = "Analysis queued…";
      else if (job.status === "running") status.textContent = job.total ? `Analyzing ${job.branch}: ${number.format(job.completed)} of ${number.format(job.total)} weeks (${Math.round(100 * job.completed / job.total)}%)` : "Reading repository history…";
      else if (job.status === "failed") status.textContent = `Analysis failed: ${job.error_message}`;
      else if (job.status === "done") status.textContent = `Analysis complete for ${job.branch}.`;
      else status.textContent = form ? "Start an analysis to see the repository's LOC history." : "LOC history has not been analyzed yet.";
      chart.hidden = job.status !== "done";
      if (job.status === "done") {
        const signature = `${job.updated_at}:${data.snapshots.length}`;
        if (signature !== lastDrawn) { render(data); lastDrawn = signature; }
      }
      if (active) setTimeout(refresh, 2000);
    } catch (error) {
      status.textContent = `Could not load LOC history: ${error.message}. Retrying…`;
      setTimeout(refresh, 5000);
    }
  }
  refresh();
})();
