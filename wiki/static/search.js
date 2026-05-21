// Simple Zola + elasticlunr search
// Place in static/search.js
document.addEventListener('DOMContentLoaded', function() {
  const searchInput = document.getElementById('search');
  const resultsContainer = document.getElementById('search-results');

  if (!searchInput || !resultsContainer) return;

  let index;
  let documents = {};

  fetch('/search_index.en.json')
    .then(response => response.json())
    .then(data => {
      index = elasticlunr.Index.load(data.index);
      documents = data.documents;
    })
    .catch(() => {
      // Fallback: no index
    });

  searchInput.addEventListener('input', function() {
    const query = this.value.trim();
    resultsContainer.innerHTML = '';
    resultsContainer.style.display = query ? 'block' : 'none';

    if (!query || !index) return;

    const results = index.search(query, { bool: 'OR', expand: true });
    results.slice(0, 8).forEach(result => {
      const doc = documents[result.ref];
      if (!doc) return;
      const el = document.createElement('a');
      el.href = doc.url;
      el.className = 'search-result';
      el.innerHTML = `<strong>${doc.title}</strong><br><small>${doc.url}</small>`;
      resultsContainer.appendChild(el);
    });
  });

  document.addEventListener('click', function(e) {
    if (!resultsContainer.contains(e.target)) {
      resultsContainer.style.display = 'none';
    }
  });
});
