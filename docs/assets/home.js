(() => {
  const examples = [
    "Let's keep the morning free for the proposal. We can catch up after lunch.",
    "Hi Anna, thanks for the update. Thursday works for me. See you at ten!",
    "An idea for the weekend: take the early train, find a quiet café, and leave the afternoon open."
  ];
  let current = 0;
  document.getElementById('sample-button').addEventListener('click', () => {
    current = (current + 1) % examples.length;
    document.getElementById('sample-text').textContent = examples[current];
  });
  document.querySelectorAll('[data-billing]').forEach(button => {
    button.addEventListener('click', () => {
      const annual = button.dataset.billing === 'annual';
      document.querySelectorAll('[data-billing]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
      document.getElementById('cloud-price').textContent = annual ? 'US$40' : 'US$4';
      document.getElementById('cloud-period').textContent = annual ? ' / year' : ' / month';
      document.getElementById('billing-note').textContent = annual ? 'Billed yearly. VAT included. Save US$8 versus monthly.' : 'Billed monthly. VAT included.';
    });
  });
  document.getElementById('cloud-cta').addEventListener('click', () => {
    document.getElementById('get-cloud').open = true;
  });
})();
