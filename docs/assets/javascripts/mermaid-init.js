window.addEventListener("load", function () {
  if (!window.mermaid) return;
  window.mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "neutral"
  });
  window.mermaid.run({ querySelector: ".mermaid" });
});
