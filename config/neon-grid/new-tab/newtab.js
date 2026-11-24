const $ = id => document.getElementById(id);
function tick() {
  const now = new Date(), h = now.getHours();
  $('clock').textContent = now.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit', hour12: false});
  const hi = h < 5 ? 'Good night' : h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
  $('hello').textContent = `${hi}  ·  ${now.toLocaleDateString([], {weekday: 'long', day: 'numeric', month: 'long'})}`;
}
tick();
setInterval(tick, 1000);
if (globalThis.chrome?.topSites) chrome.topSites.get(list => {
  for (const s of list.slice(0, 10)) {
    let host;
    try { const u = new URL(s.url); if (!/^https?:$/.test(u.protocol)) continue; host = u.hostname.replace(/^www\./, ''); } catch { continue; }
    const a = document.createElement('a'), img = document.createElement('img'), name = document.createElement('span');
    a.className = 'glass';
    a.href = s.url;
    a.title = s.title || host;
    const icon = new URL(chrome.runtime.getURL('/_favicon/'));
    icon.searchParams.set('pageUrl', s.url);
    icon.searchParams.set('size', '64');
    img.src = icon;
    img.alt = '';
    name.textContent = host;
    a.append(img, name);
    $('sites').append(a);
  }
});
