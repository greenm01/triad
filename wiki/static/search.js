document.addEventListener('DOMContentLoaded', function() {
  const searchInput = document.getElementById('search');
  const resultsContainer = document.getElementById('search-results');
  const searchContainer = document.querySelector('.search-container');

  if (!searchInput || !resultsContainer) return;

  let index;
  let documents = {};
  let indexReady = false;
  let indexFailed = false;

  function searchIndexUrl() {
    const script = document.currentScript ||
      document.querySelector('script[src$="search.js"]');
    if (!script || !script.src) return 'search_index.en.json';
    return new URL('search_index.en.json', script.src).toString();
  }

  function hideResults() {
    resultsContainer.style.display = 'none';
  }

  function showMessage(message) {
    resultsContainer.innerHTML = '';
    const el = document.createElement('div');
    el.className = 'search-empty';
    el.textContent = message;
    resultsContainer.appendChild(el);
    resultsContainer.style.display = 'block';
  }

  function renderResults(query) {
    resultsContainer.innerHTML = '';

    if (!query) {
      hideResults();
      return;
    }

    if (!indexReady) {
      showMessage(indexFailed ? 'Search unavailable' : 'Search is loading');
      return;
    }

    const results = index
      ? index.search(query, {
          bool: 'OR',
          expand: true,
          fields: {
            title: { boost: 2 },
            body: { boost: 1 },
            path: { boost: 1 },
          },
        })
      : fallbackSearch(query);

    if (results.length === 0) {
      showMessage('No results');
      return;
    }

    results.slice(0, 8).forEach(result => {
      const doc = documents[result.ref];
      if (!doc) return;

      const el = document.createElement('a');
      el.href = doc.id || result.ref;
      el.className = 'search-result';

      const title = document.createElement('strong');
      title.textContent = doc.title || doc.path || result.ref;

      const path = document.createElement('small');
      path.textContent = doc.path || result.ref;

      el.appendChild(title);
      el.appendChild(document.createElement('br'));
      el.appendChild(path);
      resultsContainer.appendChild(el);
    });

    resultsContainer.style.display = 'block';
  }

  function fallbackSearch(query) {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    return Object.values(documents)
      .map(doc => {
        const title = (doc.title || '').toLowerCase();
        const path = (doc.path || '').toLowerCase();
        const body = (doc.body || '').toLowerCase();
        let score = 0;

        terms.forEach(term => {
          if (title.includes(term)) score += 4;
          if (path.includes(term)) score += 2;
          if (body.includes(term)) score += 1;
        });

        return { ref: doc.id, score };
      })
      .filter(result => result.score > 0)
      .sort((a, b) => b.score - a.score);
  }

  fetch(searchIndexUrl())
    .then(response => {
      if (!response.ok) throw new Error('search index not found');
      return response.json();
    })
    .then(data => {
      documents = data.documents || data.documentStore.docs || {};
      if (window.elasticlunr) {
        index = elasticlunr.Index.load(data.index ? data.index : data);
      }
      indexReady = true;
      indexFailed = false;
      renderResults(searchInput.value.trim());
    })
    .catch(() => {
      indexReady = false;
      indexFailed = true;
      renderResults(searchInput.value.trim());
    });

  searchInput.addEventListener('input', function() {
    renderResults(this.value.trim());
  });

  searchInput.addEventListener('focus', function() {
    renderResults(this.value.trim());
  });

  document.addEventListener('click', function(e) {
    if (!searchContainer || !searchContainer.contains(e.target)) {
      hideResults();
    }
  });
});
