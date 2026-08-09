(function () {
  var initialized = false;

  function renderMermaid() {
    if (!window.mermaid) return;
    if (!initialized) {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: "neutral"
      });
      initialized = true;
    }
    window.mermaid.run({ querySelector: ".mermaid" });
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(renderMermaid);
  } else {
    window.addEventListener("load", renderMermaid);
  }
})();
