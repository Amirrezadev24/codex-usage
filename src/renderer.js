const $ = id => document.getElementById(id);
const compact = value => value >= 1e6 ? `${(value / 1e6).toFixed(1)}M` : value >= 1e3 ? `${(value / 1e3).toFixed(1)}K` : Math.round(value).toString();
const countdown = stamp => { if (!stamp) return 'Reset unavailable'; const seconds = Math.max(0, Math.floor((stamp - Date.now()) / 1000)), d = Math.floor(seconds / 86400), h = Math.floor(seconds % 86400 / 3600), m = Math.floor(seconds % 3600 / 60); return d ? `Resets in ${d}d ${h}h` : h ? `Resets in ${h}h ${m}m` : `Resets in ${m}m`; };
function limitCard(limit) {
  const color = limit.usedPercent >= 90 ? '#ff756f' : limit.usedPercent >= 70 ? '#ffad55' : '#98f7c8';
  const el = document.createElement('article'); el.className = 'limit';
  el.innerHTML = `<div class="limit-top"><span class="limit-title"><b></b><small></small></span><span class="percent"></span></div><div class="bar"><i></i></div><div class="limit-foot"><span class="used"></span><span class="reset"></span></div>`;
  el.querySelector('.limit-title b').textContent = limit.label; el.querySelector('.limit-title small').textContent = limit.detail.toUpperCase();
  el.querySelector('.percent').textContent = `${Math.round(limit.remainingPercent)}% LEFT`; el.querySelector('.percent').style.color = color;
  el.querySelector('.bar i').style.width = `${limit.remainingPercent}%`; el.querySelector('.bar i').style.background = color;
  el.querySelector('.used').textContent = `${Math.round(limit.usedPercent)}% USED`; el.querySelector('.reset').textContent = countdown(limit.resetAt); return el;
}
async function refresh() {
  $('status').textContent = 'REFRESHING'; $('refresh').disabled = true;
  try {
    const data = await window.pulse.snapshot(); $('plan').textContent = data.plan.label; $('status').textContent = data.source.toUpperCase();
    $('limits').replaceChildren(...data.limits.map(limitCard)); $('total').textContent = compact(data.tokens.total); $('cached').textContent = compact(data.tokens.cached);
    $('estimate').textContent = data.estimate ? `~ ${compact(data.estimate)} tokens` : 'Calibrating…'; $('source').textContent = data.source.toUpperCase();
    $('updated').textContent = ` · Updated ${new Date().toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' })}`;
    $('notice').textContent = data.warning || 'Token remainder is a rough estimate; OpenAI dynamically meters model, context, reasoning, and tools.';
  } catch (error) { $('status').textContent = 'ATTENTION'; $('notice').textContent = error.message; $('notice').style.color = '#ff756f'; }
  finally { $('refresh').disabled = false; }
}
let isCompact = false;
$('close').addEventListener('click', () => window.pulse.hide()); $('refresh').addEventListener('click', refresh);
$('compact').addEventListener('click', () => { isCompact = !isCompact; document.body.classList.toggle('compact', isCompact); window.pulse.compact(isCompact); });
window.pulse.onRefresh(refresh); refresh(); setInterval(refresh, 60000);
