document.addEventListener('DOMContentLoaded', function() {
  const searchInput = document.getElementById('search');
  const resultsContainer = document.getElementById('search-results');
  const searchContainer = document.querySelector('.search-container');

  if (!searchInput || !resultsContainer) return;

  let documents = {};
  let indexReady = false;
  let indexFailed = false;

  function searchIndexUrls() {
    const urls = [new URL('/search_index.en.json', window.location.origin).toString()];
    const script = document.currentScript ||
      document.querySelector('script[src$="search.js"]');

    if (script && script.src) {
      urls.push(new URL('search_index.en.json', script.src).toString());
    }

    urls.push(new URL('search_index.en.json', window.location.href).toString());
    return [...new Set(urls)];
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

    const results = searchDocuments(query);

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

  function searchDocuments(query) {
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

  function fetchSearchIndex(urls) {
    const [url, ...fallbacks] = urls;

    return fetch(url)
      .then(response => {
        if (!response.ok) throw new Error('search index not found');
        return response.json();
      })
      .catch(error => {
        if (fallbacks.length === 0) throw error;
        return fetchSearchIndex(fallbacks);
      });
  }

  fetchSearchIndex(searchIndexUrls())
    .then(data => {
      documents = data.documents || (data.documentStore && data.documentStore.docs) || {};
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
