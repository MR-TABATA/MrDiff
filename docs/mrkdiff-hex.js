// Start with a still image: motion is always an explicit choice.
const demoImage = document.getElementById('demo-image');
const demoToggle = document.getElementById('demo-toggle');
if (demoImage && demoToggle) {
  demoToggle.hidden = false;
  demoToggle.addEventListener('click', () => {
    const playing = demoToggle.getAttribute('aria-pressed') !== 'true';
    demoImage.src = playing ? demoImage.dataset.animation : demoImage.dataset.still;
    demoToggle.setAttribute('aria-pressed', String(playing));
    demoToggle.textContent = playing ? demoToggle.dataset.pause : demoToggle.dataset.play;
  });
}
