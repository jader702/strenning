const channelsEl = document.getElementById('channels');
const player = document.getElementById('player');
const viewerTitle = document.getElementById('viewerTitle');
const viewerUrl = document.getElementById('viewerUrl');
const overallStatus = document.getElementById('overallStatus');
const certDate = document.getElementById('certDate');
const containersState = document.getElementById('containersState');
const updatedAt = document.getElementById('updatedAt');
const channelForm = document.getElementById('channelForm');
const probeButton = document.getElementById('probeButton');
const formStatus = document.getElementById('formStatus');

let hls;

function absoluteUrl(path) {
  return new URL(path, window.location.origin).toString();
}

function formatDate(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString('pt-BR');
}

function playChannel(channel) {
  const url = absoluteUrl(channel.public_path);
  viewerTitle.textContent = channel.name;
  viewerUrl.textContent = url;

  if (hls) {
    hls.destroy();
    hls = undefined;
  }

  if (player.canPlayType('application/vnd.apple.mpegurl')) {
    player.src = url;
  } else if (window.Hls && window.Hls.isSupported()) {
    hls = new Hls({ lowLatencyMode: true, liveSyncDurationCount: 3 });
    hls.loadSource(url);
    hls.attachMedia(player);
  } else {
    player.removeAttribute('src');
  }

  player.play().catch(() => {});
}

function renderChannel(channel) {
  const card = document.createElement('article');
  card.className = 'channel';

  const publicUrl = absoluteUrl(channel.public_path);
  card.innerHTML = `
    <div class="channel-head">
      <div>
        <h2></h2>
        <span class="meta"></span>
      </div>
      <span class="badge"></span>
    </div>
    <div class="url-row">
      <input readonly>
      <button type="button">Copiar</button>
      <button type="button">Ver</button>
    </div>
  `;

  card.querySelector('h2').textContent = channel.name;
  card.querySelector('.meta').textContent =
    `Servico: ${channel.service_state || '-'} | Playlist: ${channel.playlist_age_seconds || '-'}s`;

  const badge = card.querySelector('.badge');
  badge.textContent = channel.status;
  badge.classList.add(channel.status === 'online' ? 'online' : 'offline');

  const input = card.querySelector('input');
  input.value = publicUrl;

  const buttons = card.querySelectorAll('button');
  buttons[0].addEventListener('click', async () => {
    await navigator.clipboard.writeText(publicUrl);
    buttons[0].textContent = 'Copiado';
    setTimeout(() => { buttons[0].textContent = 'Copiar'; }, 1300);
  });
  buttons[1].addEventListener('click', () => playChannel(channel));

  return card;
}

async function loadStatus() {
  const response = await fetch('status.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`status ${response.status}`);
  const data = await response.json();

  certDate.textContent = formatDate(data.certificate?.not_after_iso) || '—';
  containersState.textContent =
    data.containers?.state === 'not_installed' ? 'Docker nao instalado' : data.containers?.state || '—';
  updatedAt.textContent = formatDate(data.generated_at) || '—';

  channelsEl.innerHTML = '';
  const channels = data.channels || [];
  channels.forEach(channel => channelsEl.appendChild(renderChannel(channel)));

  const online = channels.filter(channel => channel.status === 'online').length;
  const dot = document.createElement('span');
  dot.className = 'status-dot';
  overallStatus.innerHTML = '';
  overallStatus.appendChild(dot);
  overallStatus.appendChild(document.createTextNode(` ${online}/${channels.length} online`));
  overallStatus.className = 'status-pill';
  if (online === channels.length && channels.length > 0) overallStatus.classList.add('ok');
  else if (online > 0) overallStatus.classList.add('warn');
  else if (channels.length > 0) overallStatus.classList.add('err');

  const firstOnline = channels.find(channel => channel.status === 'online') || channels[0];
  if (firstOnline) playChannel(firstOnline);
}

function formPayload() {
  const data = new FormData(channelForm);
  return {
    name: String(data.get('name') || '').trim(),
    slug: String(data.get('slug') || '').trim().toLowerCase(),
    source_url: String(data.get('source_url') || '').trim(),
    mode: String(data.get('mode') || 'copy')
  };
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

probeButton.addEventListener('click', async () => {
  formStatus.textContent = 'Testando RTSP';
  probeButton.disabled = true;
  try {
    const data = await postJson('/admin/api/probe', formPayload());
    const stream = data.stream || {};
    const codec = stream.codec_name || 'desconhecido';
    const size = stream.width && stream.height ? ` ${stream.width}x${stream.height}` : '';
    const normalized = data.source_url_normalized ? ' | playlist detectada' : '';
    formStatus.textContent = `Video ${codec}${size}${normalized}`;
  } catch (error) {
    formStatus.textContent = error.message;
  } finally {
    probeButton.disabled = false;
  }
});

channelForm.addEventListener('submit', async event => {
  event.preventDefault();
  formStatus.textContent = 'Criando canal';
  const submit = channelForm.querySelector('button[type="submit"]');
  submit.disabled = true;
  try {
    const data = await postJson('/admin/api/channels', formPayload());
    formStatus.textContent = `Canal criado: ${data.public_path}`;
    channelForm.reset();
    await loadStatus();
  } catch (error) {
    formStatus.textContent = error.message;
  } finally {
    submit.disabled = false;
  }
});

loadStatus().catch(error => {
  overallStatus.textContent = 'Erro';
  channelsEl.textContent = `Falha ao carregar status: ${error.message}`;
});

setInterval(loadStatus, 30000);
