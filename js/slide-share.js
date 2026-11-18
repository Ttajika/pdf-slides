/* ════════════════════════════════════════════════════════════════════════
   slide-share.js — PDF のアップロードと共有リンク（Supabase Storage + supabase/setup.sql の関数）

   先に supabase-js と js/slide-sync.js を読み込み、SlideSync.init(...) しておくこと
   （Supabase クライアントは SlideSync.client() を使う）。

     SlideShare.create(password, title, file)  → { id, key }      新規アップロード
     SlideShare.replace(id, key, file, title)  → version          差し替え（共有リンクはそのまま）
     SlideShare.get(id)                        → { title, url, version, expires } | null
     SlideShare.check(id, key)                 → 期限 Date（鍵が違えば例外）
     SlideShare.extend(id, key)                → 新しい期限 Date（今から 30 日）
     SlideShare.remove(id, key)
     SlideShare.links(id, key)                 → { share, presenter, record }
     SlideShare.mine() / remember(...) / forget(id)   この端末でアップロードしたものの控え
   ════════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const BUCKET = 'slides';
  const MAX_BYTES = 50 * 1024 * 1024;
  const MINE_KEY = 'pdfslides_mine';
  const SH = {};

  function client() {
    const c = window.SlideSync && SlideSync.client();
    if (!c) throw new Error('Supabase に接続できません（設定またはネットワークを確認してください）');
    return c;
  }
  // サーバのエラーを日本語に
  function friendly(e) {
    const m = (e && (e.message || e.error_description || e.error)) || String(e);
    if (/wrong password/.test(m)) return 'アップロード用パスワードが違います';
    if (/invalid key/.test(m)) return '発表者リンクが正しくありません';
    if (/expired/.test(m)) return 'このリンクは期限切れか、削除されています';
    if (/file not uploaded/.test(m)) return 'ファイルのアップロードが完了していません';
    if (/row-level security|Unauthorized|403/.test(m)) return 'アップロードが許可されませんでした（15 分以上たった場合はやり直してください）';
    if (/exceeded|too large|413/i.test(m)) return 'ファイルが大きすぎます（50MB まで）';
    if (/Could not find the function|PGRST202/.test(m)) return 'Supabase の設定（supabase/setup.sql）がまだ実行されていません';
    return m;
  }
  async function rpc(fn, args) {
    const { data, error } = await client().rpc(fn, args);
    if (error) throw new Error(friendly(error));
    return data;
  }
  function checkFile(file) {
    if (!file) throw new Error('PDF を選んでください');
    if (!/\.pdf$/i.test(file.name) && file.type !== 'application/pdf') throw new Error('PDF ファイルを選んでください');
    if (file.size > MAX_BYTES) throw new Error('ファイルが大きすぎます（50MB まで）');
  }
  async function put(path, file) {
    const { error } = await client().storage.from(BUCKET).upload(path, file,
      { contentType: 'application/pdf', upsert: false, cacheControl: '31536000' });
    if (error) throw new Error(friendly(error));
  }

  SH.create = async function (password, title, file) {
    checkFile(file);
    const rows = await rpc('slide_create', { p_password: password, p_title: title });
    const r = rows && rows[0];
    if (!r) throw new Error('発行に失敗しました');
    await put(r.upload_path, file);
    await rpc('slide_commit', { p_id: r.id, p_key: r.edit_key, p_title: title });
    return { id: r.id, key: r.edit_key };
  };
  SH.replace = async function (id, key, file, title) {
    checkFile(file);
    const path = await rpc('slide_begin_replace', { p_id: id, p_key: key });
    await put(path, file);
    return rpc('slide_commit', { p_id: id, p_key: key, p_title: title || '' });
  };
  SH.get = async function (id) {
    const rows = await rpc('slide_get', { p_id: id });
    const r = rows && rows[0];
    if (!r || !r.path) return null;
    const url = client().storage.from(BUCKET).getPublicUrl(r.path).data.publicUrl;
    return { title: r.title, url, version: r.version, updated: new Date(r.updated_at), expires: new Date(r.expires_at) };
  };
  SH.check = async (id, key) => new Date(await rpc('slide_check', { p_id: id, p_key: key }));
  SH.extend = async (id, key) => new Date(await rpc('slide_extend', { p_id: id, p_key: key }));
  SH.remove = async (id, key) => { await rpc('slide_delete', { p_id: id, p_key: key }); };

  SH.links = function (id, key) {
    const base = location.origin + location.pathname.replace(/[^/]*$/, '') + 'viewer.html?s=' + encodeURIComponent(id);
    return { share: base, record: base + '&rec=1', presenter: key ? base + '&k=' + encodeURIComponent(key) : null };
  };

  // ── この端末でアップロードしたものの控え（発表者リンクを失くさないため）────
  function readMine() { try { return JSON.parse(localStorage.getItem(MINE_KEY) || '[]'); } catch (e) { return []; } }
  function writeMine(a) { try { localStorage.setItem(MINE_KEY, JSON.stringify(a)); } catch (e) {} }
  SH.mine = readMine;
  SH.remember = function (item) {   // { id, key, title, expires }
    const a = readMine().filter(x => x.id !== item.id);
    a.unshift(Object.assign({}, item, { expires: item.expires ? new Date(item.expires).toISOString() : null }));
    writeMine(a.slice(0, 100));
  };
  SH.forget = id => writeMine(readMine().filter(x => x.id !== id));

  SH.fmtDate = d => d ? `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}` : '';
  SH.qrSvg = function (text) {
    if (typeof qrcode !== 'function') return '';
    try { const q = qrcode(0, 'M'); q.addData(text); q.make(); return q.createSvgTag({ cellSize: 4, margin: 2 }); } catch (e) { return ''; }
  };
  SH.copy = async function (text) {
    try { await navigator.clipboard.writeText(text); return true; }
    catch (e) { window.prompt('コピーしてください', text); return false; }
  };

  window.SlideShare = SH;
})();
