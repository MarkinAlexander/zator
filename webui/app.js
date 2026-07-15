const state = {
  locks: [],
  status: null,
  strategyChecks: {},
};

const views = {
  status: document.getElementById('view-status'),
  strategies: document.getElementById('view-strategies'),
};

const toastRegion = document.getElementById('toast-region');
let activeToast = null;
let activeToastTimer = 0;

function dismissToast() {
  if (!activeToast) return;
  window.clearTimeout(activeToastTimer);
  const node = activeToast;
  activeToast = null;
  node.classList.remove('is-visible');
  const removeNode = () => node.remove();
  node.addEventListener('transitionend', removeNode, { once: true });
  window.setTimeout(removeNode, 300);
}

function showToast(message, type = 'success') {
  if (!toastRegion) return;
  if (activeToast) {
    activeToast.remove();
    activeToast = null;
  }
  window.clearTimeout(activeToastTimer);

  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  if (type === 'error') {
    toast.setAttribute('role', 'alert');
  }

  const msg = document.createElement('div');
  msg.className = 'toast-message';
  msg.textContent = message;
  toast.appendChild(msg);

  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'toast-close';
  close.setAttribute('aria-label', 'Закрыть уведомление');
  close.textContent = '×';
  close.addEventListener('click', dismissToast);
  toast.appendChild(close);

  toastRegion.appendChild(toast);
  activeToast = toast;

  requestAnimationFrame(() => toast.classList.add('is-visible'));

  // ошибки 8 секунд, обычное уведомление три с половиной
  const duration = type === 'error' ? 8000 : 3500;
  activeToastTimer = window.setTimeout(dismissToast, duration);
}

let activeOperation = false;

const ACTION_SELECTORS = [
  '#toggle-service',
  '#restart-service',
  '#refresh-status',
  '#run-check',
  '#refresh-locks',
  '#strategy-cards .lock-form button[type="submit"]',
  '#strategy-cards .lock-form .clear-lock',
];

function getActionControls() {
  return document.querySelectorAll(ACTION_SELECTORS.join(','));
}

function lockAllControls() {
  getActionControls().forEach((control) => {
    control.disabled = true;
  });
}

function unlockAllControls() {
  getActionControls().forEach((control) => {
    control.disabled = false;
  });
  renderServiceControls();
}

function setBusy(element, busy) {
  if (!element) return;
  element.classList.toggle('is-busy', busy);
  element.disabled = busy;
  if (busy) {
    element.setAttribute('aria-busy', 'true');
  } else {
    element.removeAttribute('aria-busy');
  }
}

async function withBusy(element, task) {
  activeOperation = true;
  lockAllControls();
  setBusy(element, true);
  try {
    return await task();
  } finally {
    setBusy(element, false);
    activeOperation = false;
    unlockAllControls();
  }
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  let data = {};
  try {
    data = await response.json();
  } catch (_) {
    data = {};
  }
  if (!response.ok) {
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

function applyTheme(theme) {
  const normalized = ['auto', 'light', 'dark'].includes(theme) ? theme : 'auto';
  document.documentElement.dataset.theme = normalized;
  const select = document.getElementById('theme-mode');
  if (select) {
    select.value = normalized;
  }
}

function initTheme() {
  let savedTheme = 'auto';
  try {
    savedTheme = localStorage.getItem('z2r-theme') || 'auto';
  } catch (_) {
    savedTheme = 'auto';
  }
  const select = document.getElementById('theme-mode');
  applyTheme(savedTheme);
  if (select) {
    select.addEventListener('change', () => {
      try {
        localStorage.setItem('z2r-theme', select.value);
      } catch (_) {
        // Theme still applies for the current session when storage is unavailable.
      }
      applyTheme(select.value);
    });
  }
}

function switchView(view) {
  Object.entries(views).forEach(([name, element]) => {
    element.classList.toggle('is-active', name === view);
  });
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.classList.toggle('is-active', tab.dataset.view === view);
  });
}

function renderServiceControls() {
  const toggleButton = document.getElementById('toggle-service');
  const restartButton = document.getElementById('restart-service');
  if (!toggleButton || !restartButton || !state.status) return;

  const running = Boolean(state.status.zapret2_running);
  toggleButton.dataset.action = running ? 'stop' : 'start';
  toggleButton.textContent = running ? 'Остановить zapret2' : 'Включить zapret2';
  toggleButton.classList.toggle('is-stop', running);
  toggleButton.classList.toggle('is-start', !running);

  restartButton.disabled = !running;
  restartButton.title = running ? 'Перезапустить zapret2' : 'zapret2 остановлен';
  restartButton.setAttribute('aria-label', restartButton.title);

  const serviceControl = toggleButton.closest('.service-control');
  if (serviceControl) {
    serviceControl.classList.toggle('is-running', running);
  }
}

function renderStatus() {
  if (!state.status) return;
  renderServiceControls();

  const statusCards = document.getElementById('status-cards');
  const statusProfiles = document.getElementById('status-profiles');
  const statTemplate = document.getElementById('status-card-template');
  const profileTemplate = document.getElementById('status-profile-template');

  statusCards.innerHTML = '';
  statusProfiles.innerHTML = '';

  const cards = [
    ['zapret2', state.status.zapret2_running ? 'Запущен' : 'Остановлен', state.status.zapret2_running ? 'ok' : 'bad'],
    ['Локи стратегий', state.status.strategy_locks_status],
    ['Фильтр', state.status.hostlist_mode],
    ['FW', state.status.fwtype],
    ['Offload', state.status.flowoffload],
    ['TLS blob', state.status.tls_blob_mode],
  ];

  cards.forEach(([label, value, stateClass]) => {
    const node = statTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('.label').textContent = label;
    const valueEl = node.querySelector('.value');
    valueEl.textContent = value ?? '—';
    if (stateClass) valueEl.classList.add(stateClass);
    statusCards.appendChild(node);
  });

  const profiles = Array.isArray(state.status.profiles) ? state.status.profiles : [];
  profiles.forEach((profile) => {
    const node = profileTemplate.content.firstElementChild.cloneNode(true);
    node.querySelector('h3').textContent = profile.label;
    node.querySelector('.desc').textContent = profile.description;
    node.querySelector('.current-lock').textContent = profile.current_lock || '0';
    statusProfiles.appendChild(node);
  });
}

function renderStrategies() {
  const container = document.getElementById('strategy-cards');
  const template = document.getElementById('strategy-card-template');
  container.innerHTML = '';

  state.locks.forEach((profile) => {
    const node = template.content.firstElementChild.cloneNode(true);
    node.querySelector('h3').textContent = profile.label;
    node.querySelector('.desc').textContent = profile.description;
    node.querySelector('.chip').textContent = `Профиль ${profile.profile}`;
    node.querySelector('.current-lock').textContent = profile.current_lock || '0';
    node.querySelector('.max-lock').textContent = String(profile.max_strategy);

    const input = node.querySelector('input');
    const form = node.querySelector('.lock-form');
    const submitButton = form.querySelector('button[type="submit"]');
    const clearButton = node.querySelector('.clear-lock');
    const inlineCheck = node.querySelector('.inline-check');
    const stepButtons = node.querySelectorAll('.step-strategy');

    input.min = '0';
    input.max = String(profile.max_strategy);
    if (/^[0-9]+$/.test(String(profile.current_lock || ''))) {
      input.value = profile.current_lock;
    }
    if (state.strategyChecks[profile.profile]) {
      renderCheckResults(inlineCheck, state.strategyChecks[profile.profile], 'Нет результатов быстрой проверки.', false);
    }

    stepButtons.forEach((button) => {
      button.addEventListener('click', () => {
        const step = Number(button.dataset.step || 0);
        const min = Number(input.min || 1);
        const max = Number(input.max || profile.max_strategy || min);
        const parsed = Number(input.value || profile.current_lock);
        const current = Number.isFinite(parsed) ? parsed : min;
        const next = Math.min(max, Math.max(min, current + step));
        input.value = String(next);
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });
    });

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const rawValue = input.value.trim();
      const value = Number(rawValue);
      if (!/^[0-9]+$/.test(rawValue) || value > Number(input.max || profile.max_strategy || 0)) {
        showToast('Введите номер стратегии.', 'error');
        return;
      }
      try {
        let payload = null;
        await withBusy(submitButton, async () => {
          payload = await api('/cgi-bin/set-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile, strategy: value }),
          });
          state.strategyChecks[profile.profile] = payload?.check;
          await refreshAll();
        });
        showToast(value === 0 ? `Профиль ${profile.label} выключен.` : `Стратегия ${value} сохранена для ${profile.label}.`);
      } catch (error) {
        showToast(error.message, 'error');
      }
    });

    clearButton.addEventListener('click', async () => {
      try {
        await withBusy(clearButton, async () => {
          await api('/cgi-bin/clear-lock.cgi', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ profile: profile.profile }),
          });
          delete state.strategyChecks[profile.profile];
          await refreshAll();
        });
        showToast(`Lock снят для ${profile.label}.`);
      } catch (error) {
        showToast(error.message, 'error');
      }
    });

    container.appendChild(node);
  });
}

function appendText(parent, tag, text, className) {
  const element = document.createElement(tag);
  if (className) {
    element.className = className;
  }
  element.textContent = text;
  parent.appendChild(element);
  return element;
}

function renderCheckResults(container, payload, emptyMessage, emptyIsHidden = true) {
  if (!container) return;
  container.innerHTML = '';

  const results = Array.isArray(payload?.results) ? payload.results : [];
  if (!results.length) {
    container.classList.toggle('empty', emptyIsHidden && !payload?.message);
    container.textContent = payload?.message || emptyMessage;
    return;
  }

  container.classList.remove('empty');
  results.forEach((item) => {
    const article = document.createElement('article');
    article.className = 'check-item';

    const title = document.createElement('div');
    title.className = 'check-title';
    appendText(title, 'strong', item.label || 'Цель');
    appendText(title, 'span', item.target || '');

    const pair = document.createElement('div');
    pair.className = 'check-pair';
    appendText(pair, 'span', `TLS 1.2: ${item.tls12 ? 'OK' : 'FAIL'}`, item.tls12 ? 'ok' : 'bad');
    appendText(pair, 'span', `TLS 1.3: ${item.tls13 ? 'OK' : 'FAIL'}`, item.tls13 ? 'ok' : 'bad');

    article.append(title, pair);
    container.appendChild(article);
  });
}

async function refreshAll() {
  const status = await api('/cgi-bin/status.cgi');
  state.status = status;
  state.locks = status.profiles || [];
  renderStatus();
  renderStrategies();
  if (activeOperation) lockAllControls();
}

initTheme();

document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => switchView(tab.dataset.view));
});

document.getElementById('open-strategies').addEventListener('click', () => switchView('strategies'));
document.getElementById('refresh-status').addEventListener('click', (event) => {
  withBusy(event.currentTarget, refreshAll).catch((e) => showToast(e.message, 'error'));
});
document.getElementById('refresh-locks').addEventListener('click', (event) => {
  withBusy(event.currentTarget, refreshAll).catch((e) => showToast(e.message, 'error'));
});

async function runServiceAction(button, action) {
  const successMessages = {
    start: 'zapret2 включен.',
    stop: 'zapret2 выключен.',
    restart: 'zapret2 перезапущен.',
  };
  const successMessage = successMessages[action] || 'Команда выполнена.';
  try {
    await withBusy(button, async () => {
      await api('/cgi-bin/service.cgi', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ action }),
      });
      await refreshAll();
    });
    showToast(successMessage);
  } catch (error) {
    showToast(error.message, 'error');
  }
}

document.getElementById('toggle-service').addEventListener('click', (event) => {
  const action = event.currentTarget.dataset.action || (state.status?.zapret2_running ? 'stop' : 'start');
  runServiceAction(event.currentTarget, action);
});

document.getElementById('restart-service').addEventListener('click', (event) => {
  runServiceAction(event.currentTarget, 'restart');
});

document.getElementById('run-check').addEventListener('click', async (event) => {
  try {
    const payload = await withBusy(event.currentTarget, () => api('/cgi-bin/check.cgi', { method: 'POST' }));
    renderCheckResults(document.getElementById('check-results'), payload, 'Нет результатов проверки.');
    showToast('Проверка завершена.');
  } catch (error) {
    showToast(error.message, 'error');
  }
});

refreshAll().catch((error) => {
  showToast(error.message, 'error');
});
