(function () {
  var initialized = false;
  var renderQueue = Promise.resolve();

  function describeError(error) {
    if (error && error.message) return error.message;
    return String(error);
  }

  function renderMermaid() {
    if (!window.mermaid) return;
    if (!initialized) {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: "neutral"
      });
      window.mermaid.parseError = function (error) {
        console.error("Mermaid parse failed: " + describeError(error));
      };
      initialized = true;
    }
    var nodes = Array.prototype.slice.call(
      document.querySelectorAll(".mermaid:not([data-processed])")
    );
    if (!nodes.length) return;
    renderQueue = renderQueue
      .then(function () {
        return window.mermaid.run({ nodes: nodes });
      })
      .catch(function (error) {
        console.error("Mermaid render failed: " + describeError(error));
      });
  }

  if (typeof document$ !== "undefined") {
    document$.subscribe(renderMermaid);
  } else {
    window.addEventListener("load", renderMermaid);
  }
})();
