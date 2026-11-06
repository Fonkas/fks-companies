'use strict';

/* =====================================================================
   fks-companies documents: the employment contract and the payment request (bill).
   Loaded INTO the fks-core NUI as an extension (UI.Extend in client/documents.lua), so the server still
   runs one NUI frame. Everything else of the resource uses the fks-core components.
   Lua -> JS : 'contract:show' / 'contract:hide' / 'bill:show' / 'bill:hide'
   JS -> Lua : api.call('contract', { token, accept })  -> { ok, signature, message }
               api.call('bill', { id, accept })         -> { ok, message }
               api.call('closed', {})                   (the document left the screen)
   ===================================================================== */
(() => {
    const owner = document.currentScript.dataset.owner;
    let api = null;
    let root = null;
    let timer = null;
    let current = null;       // { kind, id }

    const el = (tag, cls, text) => {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text !== undefined && text !== null) e.textContent = text;
        return e;
    };
    const money = (n) => {
        const x = Number(n) || 0;
        return `$${x.toLocaleString('en-US', { minimumFractionDigits: x % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
    };
    const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

    function clear() {
        if (timer) clearInterval(timer);
        timer = null;
        current = null;
        if (root) root.innerHTML = '';
    }

    function hide(notify) {
        if (!root || !root.firstChild) { clear(); return; }
        const doc = root.firstChild;
        doc.classList.add('fco-out');
        setTimeout(() => { clear(); }, 380);
        api.focus(false);
        if (notify) api.call('closed', {});
    }

    // countdown in the corner; at 0 the document expires on its own
    function countdown(node, seconds, label) {
        const end = Date.now() + seconds * 1000;
        const tick = () => {
            const left = Math.max(0, (end - Date.now()) / 1000);
            node.textContent = `${label} ${mmss(left)}`;
            node.classList.toggle('fco-late', left < 15);
            if (left <= 0) hide(true);
        };
        tick();
        timer = setInterval(tick, 500);
    }

    function buttons(onAccept, onDecline, acceptText, declineText) {
        const row = el('div', 'fco-actions');
        const no = el('button', 'btn ghost fco-decline', declineText);
        const yes = el('button', 'btn fco-accept', acceptText);
        no.addEventListener('click', () => { if (!row.classList.contains('busy')) onDecline(row); });
        yes.addEventListener('click', () => { if (!row.classList.contains('busy')) onAccept(row); });
        row.append(no, yes);
        return row;
    }

    function status(doc, text, bad) {
        let s = doc.querySelector('.fco-status');
        if (!s) { s = el('div', 'fco-status'); doc.appendChild(s); }
        s.textContent = text || '';
        s.classList.toggle('bad', !!bad);
    }

    /* ------------------------------------------------------------ contract */
    function contract(d) {
        clear();
        current = { kind: 'contract', id: d.token };
        const t = d.text || {};
        const doc = el('div', 'fco-doc fco-contract');

        const head = el('div', 'fco-head');
        head.append(el('div', 'fco-eyebrow', t.eyebrow), el('h1', 'fco-title', t.title), el('div', 'fco-company', d.company));
        const meta = el('div', 'fco-meta');
        meta.append(el('span', '', `${t.number} ${d.number}`), el('span', '', d.date));
        const timeLeft = el('span', 'fco-timer');
        meta.appendChild(timeLeft);
        head.appendChild(meta);
        doc.appendChild(head);
        doc.appendChild(el('div', 'fco-rule'));

        const body = el('div', 'fco-body');
        const p1 = el('p', 'fco-lead');
        p1.append(t.between, ' ', el('b', '', d.company), ` (${d.code}), `, t.represented, ' ', el('b', '', d.employer),
            d.employerRole ? `, ${d.employerRole}` : '', ', ', t.and, ' ', el('b', '', d.employee), ', ', t.agreed);
        body.appendChild(p1);

        const terms = el('dl', 'fco-terms');
        const term = (k, v) => { if (v) { terms.append(el('dt', '', k), el('dd', '', v)); } };
        term(t.position, `${d.position}`);
        term(t.grade, String(d.grade));
        term(t.employer, d.employer);
        term(t.start, t.immediately);
        body.appendChild(terms);

        if (d.description) {
            body.appendChild(el('h3', 'fco-sub', t.duties));
            body.appendChild(el('p', 'fco-desc', d.description));
        }
        if (d.permissions && d.permissions.length) {
            body.appendChild(el('h3', 'fco-sub', t.authority));
            const ul = el('ul', 'fco-perms');
            d.permissions.forEach((p) => ul.appendChild(el('li', '', p)));
            body.appendChild(ul);
        }
        body.appendChild(el('p', 'fco-clauses', t.clauses));
        doc.appendChild(body);

        // signatures
        const sigs = el('div', 'fco-sigs');
        const left = el('div', 'fco-sig');
        left.append(el('div', 'fco-ink signed', d.employer), el('div', 'fco-line'), el('small', '', t.employerSig));
        const right = el('div', 'fco-sig');
        const ink = el('div', 'fco-ink');
        right.append(ink, el('div', 'fco-line'), el('small', '', t.employeeSig));
        sigs.append(left, right);
        doc.appendChild(sigs);

        const seal = el('div', 'fco-seal');
        seal.appendChild(el('span', '', d.code));
        doc.appendChild(seal);

        doc.appendChild(buttons(async (row) => {
            row.classList.add('busy');
            status(doc, t.signing);
            const res = await api.call('contract', { token: d.token, accept: true });
            if (!res || !res.ok) {
                row.classList.remove('busy');
                status(doc, (res && res.message) || t.failed, true);
                return;
            }
            if (timer) clearInterval(timer);
            timeLeft.textContent = '';
            ink.textContent = res.signature || d.employee;
            ink.classList.add('writing');
            seal.classList.add('stamped');
            status(doc, res.message || '');
            row.remove();
            setTimeout(() => hide(false), 3200);
        }, async (row) => {
            row.classList.add('busy');
            await api.call('contract', { token: d.token, accept: false });
            hide(false);
        }, t.accept, t.decline));

        root.appendChild(doc);
        countdown(timeLeft, d.expires, t.expires);
        api.focus(true);
    }

    /* ------------------------------------------------------------ bill */
    function bill(d) {
        clear();
        current = { kind: 'bill', id: d.id };
        const t = d.text || {};
        const doc = el('div', 'fco-doc fco-bill');
        const head = el('div', 'fco-head');
        head.append(el('div', 'fco-eyebrow', t.eyebrow), el('h1', 'fco-title small', d.company));
        const meta = el('div', 'fco-meta');
        const timeLeft = el('span', 'fco-timer');
        meta.append(el('span', '', `${t.number} ${d.number}`), el('span', '', d.date), timeLeft);
        head.appendChild(meta);
        doc.appendChild(head);
        doc.appendChild(el('div', 'fco-rule'));

        const body = el('div', 'fco-body');
        const terms = el('dl', 'fco-terms');
        terms.append(el('dt', '', t.clerk), el('dd', '', d.employee));
        if (d.desc) terms.append(el('dt', '', t.for), el('dd', '', d.desc));
        body.appendChild(terms);
        const amount = el('div', 'fco-amount');
        amount.append(el('small', '', t.amount), el('b', '', money(d.amount)));
        body.appendChild(amount);
        body.appendChild(el('p', 'fco-clauses', t.note));
        doc.appendChild(body);

        doc.appendChild(buttons(async (row) => {
            row.classList.add('busy');
            const res = await api.call('bill', { id: d.id, accept: true });
            if (!res || !res.ok) {
                row.classList.remove('busy');
                status(doc, (res && res.message) || t.failed, true);
                return;
            }
            if (timer) clearInterval(timer);
            timeLeft.textContent = '';
            const stamp = el('div', 'fco-paid', t.paid);
            doc.appendChild(stamp);
            row.remove();
            setTimeout(() => hide(false), 1800);
        }, async (row) => {
            row.classList.add('busy');
            await api.call('bill', { id: d.id, accept: false });
            hide(false);
        }, t.pay, t.decline));

        root.appendChild(doc);
        countdown(timeLeft, d.seconds, t.expires);
        api.focus(true);
    }

    // Item / blip pictures in fks-core cards hide themselves when they fail to load. Inside our own lists
    // (class fco-items) a missing picture shows the fallback box instead. Capture runs before the card's
    // own onerror, so we swap the source and undo the hiding right after.
    const FALLBACK = `data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g fill="none" stroke="#cfc2a6" stroke-width="2.5" stroke-linejoin="round" opacity=".85"><path d="M14 22 32 12l18 10v20L32 52 14 42z"/><path d="M14 22l18 10 18-10M32 32v20"/></g></svg>')}`;
    document.addEventListener('error', (e) => {
        const img = e.target;
        if (!img || img.tagName !== 'IMG' || img.dataset.fcoFallback || !img.closest('.fco-items')) return;
        img.dataset.fcoFallback = '1';
        img.src = FALLBACK;
        setTimeout(() => { img.style.visibility = ''; }, 0);
    }, true);

    // ESC declines the open document
    document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape' || !current || !root || !root.firstChild) return;
        const no = root.querySelector('.fco-decline');
        if (no) no.click();
    });

    /* =================================================================
       Components (FKS.component): drawn by fks-core inside its own screens; their actions go to Lua
       like those of any core component.
         fco-select  dropdown without the native <select> (CEF draws its popup as a broken texture in RedM)
         fco-blips   round icon grid with search + categories (blip gallery)
         fco-shop    store: product grid + cart on the side, checkout in one action
         fco-stock   store products (left) next to the employee's inventory (right)
       ================================================================= */
    const C = FKS.component;
    const list = (v) => (Array.isArray(v) ? v : (v && typeof v === 'object' ? Object.values(v) : []));
    const fmt = (str, ...args) => { let i = 0; return String(str || '').replace(/%[sd]/g, () => String(args[i++] ?? '')); };
    const picture = (src, cls) => {
        const im = el('img', cls);
        im.loading = 'lazy';
        im.src = src || FALLBACK;
        im.onerror = () => { if (im.src !== FALLBACK) im.src = FALLBACK; };
        return im;
    };

    // label + control + error line: same markup (and look) as the core form fields
    function field(p, c, control) {
        if (!p.label && !p.note && !p.name) return control;
        const f = el('div', 'field');
        if (p.name) f.dataset.field = p.name;
        if (p.label) {
            const lab = el('label', '', p.label);
            if (p.optional && c.t) lab.appendChild(el('small', '', ` (${c.t('ui_optional')})`));
            f.appendChild(lab);
        }
        f.appendChild(control);
        if (p.note) f.appendChild(el('div', 'note', p.note));
        const err = el('div', 'err');
        const msg = p.name && c.error && c.error(p.name);
        if (msg) { err.textContent = msg; f.classList.add('invalid'); }
        f.appendChild(err);
        return f;
    }

    /* ---------------------------------------------------------- fco-select */
    let openPop = null;
    const closePop = () => { if (openPop) { const p = openPop; openPop = null; p.close(); } };
    document.addEventListener('mousedown', (e) => {
        if (openPop && !openPop.node.contains(e.target) && !openPop.owner.contains(e.target)) closePop();
    }, true);
    document.addEventListener('scroll', (e) => {
        if (openPop && !openPop.node.contains(e.target)) closePop();
    }, true);
    window.addEventListener('resize', closePop);
    // ESC closes the open list first (not the whole panel)
    window.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && openPop) { e.stopImmediatePropagation(); e.preventDefault(); closePop(); }
    }, true);

    C('fco-select', {
        render(p, c) {
            const opts = list(p.options).map((o) => (typeof o === 'object' ? o : { value: o, label: String(o) }));
            let cur = p.name ? c.value(p.name, p.value) : p.value;
            const box = el('div', 'fco-sel');
            const btn = el('button', 'fco-sel-btn');
            btn.type = 'button';
            btn.disabled = !!p.disabled;
            const lab = el('span', 'fco-sel-lab');
            btn.append(lab, el('i', 'fco-chev'));
            box.appendChild(btn);
            const paint = () => {
                const o = opts.find((x) => String(x.value) === String(cur));
                lab.textContent = o ? o.label : (p.placeholder || '—');
                lab.classList.toggle('fco-ph', !o);
            };
            const pick = (o) => {
                cur = o.value;
                p.value = cur;
                if (p.name) c.setValue(p.name, cur);
                paint();
                closePop();
                if (p.action) c.emit(p.action, { name: p.name, id: p.id, value: cur });
            };
            const open = () => {
                const pop = el('div', 'fco-pop');
                let search = null;
                const rows = el('div', 'fco-pop-list');
                const draw = (q) => {
                    rows.innerHTML = '';
                    const needle = (q || '').trim().toLowerCase();
                    const shown = opts.filter((o) => !needle || `${o.label} ${o.sub || ''}`.toLowerCase().includes(needle));
                    shown.forEach((o) => {
                        const r = el('div', `fco-opt${String(o.value) === String(cur) ? ' on' : ''}`);
                        if (o.img) r.appendChild(picture(o.img, 'fco-opt-img'));
                        const t = el('div', 'fco-opt-txt');
                        t.appendChild(el('span', '', o.label));
                        if (o.sub) t.appendChild(el('small', '', o.sub));
                        r.appendChild(t);
                        r.addEventListener('click', () => pick(o));
                        rows.appendChild(r);
                    });
                    if (!shown.length) rows.appendChild(el('div', 'fco-opt-none', p.empty || '—'));
                };
                if (p.search || opts.length > 8) {
                    search = el('input', 'fco-pop-search');
                    search.type = 'text';
                    search.placeholder = p.searchPlaceholder || '…';
                    search.spellcheck = false;
                    search.addEventListener('input', () => draw(search.value));
                    pop.appendChild(search);
                }
                pop.appendChild(rows);
                draw('');
                document.body.appendChild(pop);
                // follows the button (the panel may still be sliding in); closes if the button goes away
                let frame = 0;
                const place = () => {
                    if (!btn.isConnected) { closePop(); return; }
                    const r = btn.getBoundingClientRect();
                    const up = window.innerHeight - r.bottom < 260 && r.top > window.innerHeight - r.bottom;
                    pop.style.left = `${r.left}px`;
                    pop.style.width = `${Math.max(r.width, 180)}px`;
                    pop.style.top = up ? '' : `${r.bottom + 4}px`;
                    pop.style.bottom = up ? `${window.innerHeight - r.top + 4}px` : '';
                    pop.classList.toggle('up', up);
                    frame = requestAnimationFrame(place);
                };
                place();
                box.classList.add('open');
                openPop = { node: pop, owner: box, close: () => { cancelAnimationFrame(frame); pop.remove(); box.classList.remove('open'); } };
                const on = rows.querySelector('.fco-opt.on');
                if (on) on.scrollIntoView({ block: 'nearest' });
                if (search) setTimeout(() => search.focus(), 0);
            };
            btn.addEventListener('click', () => {
                if (openPop && openPop.owner === box) { closePop(); return; }
                closePop();
                open();
            });
            if (p.name && cur !== undefined) c.setValue(p.name, cur);
            paint();
            return field(p, c, box);
        },
    });

    /* ---------------------------------------------------------- fco-blips */
    C('fco-blips', {
        render(p, c) {
            const L = p.labels || {};
            const items = list(p.items);
            const cats = list(p.cats);
            let cur = p.name ? c.value(p.name, p.value) : p.value;
            let q = '';
            let cat = 'all';
            const box = el('div', `fco-blips${p.compact ? ' compact' : ''}`);

            const head = el('div', 'fco-bl-head');
            const search = el('input', 'fco-bl-search');
            search.type = 'text';
            search.placeholder = L.search || '';
            search.spellcheck = false;
            const count = el('span', 'fco-bl-count');
            head.append(search, count);
            box.appendChild(head);

            const chips = el('div', 'fco-bl-cats');
            [{ value: 'all', label: L.all || 'All' }, ...cats].forEach((k) => {
                const b = el('button', 'fco-bl-cat', k.label);
                b.type = 'button';
                b.dataset.cat = k.value;
                b.addEventListener('click', () => { cat = k.value; draw(); });
                chips.appendChild(b);
            });
            box.appendChild(chips);

            const grid = el('div', 'fco-bl-grid');
            box.appendChild(grid);
            const info = el('div', 'fco-bl-info');
            box.appendChild(info);

            const byValue = (v) => items.find((it) => String(it.v) === String(v));
            const showInfo = (it, hover) => {
                info.innerHTML = '';
                const target = it || byValue(cur);
                if (!target) { info.appendChild(el('span', 'fco-bl-none', L.none || '')); return; }
                info.appendChild(picture(target.i, 'fco-bl-info-img'));
                const t = el('div');
                t.appendChild(el('b', '', target.l));
                const tags = [];
                if (!hover && String(target.v) === String(cur)) tags.push(L.selected || '');
                if (String(target.v) === String(p.current)) tags.push(L.current || '');
                t.appendChild(el('small', '', [target.n, ...tags.filter(Boolean)].join(' · ')));
                info.appendChild(t);
            };
            const cells = [];
            const draw = () => {
                grid.innerHTML = '';
                cells.length = 0;
                chips.querySelectorAll('.fco-bl-cat').forEach((b) => b.classList.toggle('on', b.dataset.cat === cat));
                const needle = q.trim().toLowerCase();
                const shown = items.filter((it) => (cat === 'all' || it.c === cat)
                    && (!needle || it.l.toLowerCase().includes(needle) || it.n.includes(needle) || String(it.v).includes(needle)));
                shown.forEach((it) => {
                    const b = el('button', 'fco-bl');
                    b.type = 'button';
                    b.title = it.l;
                    if (String(it.v) === String(p.current)) b.classList.add('cur');
                    if (String(it.v) === String(cur)) b.classList.add('on');
                    b.appendChild(picture(it.i));
                    b.addEventListener('mouseenter', () => showInfo(it, true));
                    b.addEventListener('mouseleave', () => showInfo(null));
                    b.addEventListener('click', () => {
                        cur = it.v;
                        p.value = cur;
                        if (p.name) c.setValue(p.name, cur);
                        cells.forEach(([n, x]) => n.classList.toggle('on', x === it));
                        showInfo(null);
                        if (p.action) c.emit(p.action, { name: p.name, id: p.id, value: cur });
                    });
                    cells.push([b, it]);
                    grid.appendChild(b);
                });
                if (!shown.length) grid.appendChild(el('div', 'fco-bl-empty', L.empty || ''));
                count.textContent = fmt(L.results || '%d', shown.length);
            };
            search.addEventListener('input', () => { q = search.value; draw(); });
            if (p.name && cur !== undefined) c.setValue(p.name, cur);
            draw();
            showInfo(null);
            return field(p, c, box);
        },
    });

    /* ---------------------------------------------------------- fco-shop */
    function shopDraw(box, p) {
        const st = box._fco;
        const L = p.labels || {};
        const products = list(p.products);
        const max = Number(p.maxQty) || 100;
        const byItem = (item) => products.find((x) => x.item === item);
        const qty = (item) => st.cart.get(item) || 0;
        const set = (item, n) => {
            const pr = byItem(item);
            if (!pr) return;
            n = Math.max(0, Math.min(n, pr.quantity, max));
            if (n === 0) st.cart.delete(item); else st.cart.set(item, n);
            shopDraw(box, p);
        };
        const stepper = (item, n, limit) => {
            const s = el('div', 'fco-step');
            const minus = el('button', '', '−');
            const plus = el('button', '', '+');
            minus.type = 'button';
            plus.type = 'button';
            plus.disabled = n >= limit;
            minus.addEventListener('click', (e) => { e.stopPropagation(); set(item, n - 1); });
            plus.addEventListener('click', (e) => { e.stopPropagation(); set(item, n + 1); });
            s.append(minus, el('b', '', String(n)), plus);
            return s;
        };

        // product grid (the search box is not redrawn, so it keeps its focus)
        const grid = st.grid;
        grid.innerHTML = '';
        const needle = st.q.trim().toLowerCase();
        const shown = products.filter((x) => !needle || x.label.toLowerCase().includes(needle) || x.item.toLowerCase().includes(needle));
        shown.forEach((x) => {
            const n = qty(x.item);
            const limit = Math.min(x.quantity, max);
            const card = el('div', `fco-prod${x.quantity < 1 ? ' out' : ''}${n > 0 ? ' in' : ''}`);
            card.appendChild(picture(x.img, 'fco-prod-img'));
            card.appendChild(el('div', 'fco-prod-name', x.label));
            const meta = el('div', 'fco-prod-meta');
            meta.append(el('span', 'fco-price', money(x.price)), el('span', 'fco-stock', x.quantity < 1 ? (L.soldOut || '') : fmt(L.stock, x.quantity)));
            card.appendChild(meta);
            if (x.quantity < 1) {
                card.appendChild(el('div', 'fco-prod-out', L.soldOut || ''));
            } else if (n > 0) {
                card.appendChild(stepper(x.item, n, limit));
            } else {
                const add = el('button', 'fco-add', L.add || '+');
                add.type = 'button';
                add.addEventListener('click', () => set(x.item, 1));
                card.appendChild(add);
            }
            if (x.description) card.title = x.description;
            grid.appendChild(card);
        });
        if (!shown.length) grid.appendChild(el('div', 'fco-shop-empty', products.length ? (L.noResults || '') : (L.empty || '')));

        // cart
        const lines = st.lines;
        lines.innerHTML = '';
        let total = 0;
        let units = 0;
        const order = [];
        st.cart.forEach((n, item) => {
            const x = byItem(item);
            if (!x) return;
            total += x.price * n;
            units += n;
            order.push({ item, qty: n, price: x.price });
            const row = el('div', 'fco-cline');
            row.appendChild(picture(x.img, 'fco-cline-img'));
            const mid = el('div', 'fco-cline-mid');
            mid.append(el('span', 'fco-cline-name', x.label), el('small', '', `${n} × ${money(x.price)}`));
            row.appendChild(mid);
            row.appendChild(stepper(item, n, Math.min(x.quantity, max)));
            row.appendChild(el('span', 'fco-cline-sub', money(x.price * n)));
            const del = el('button', 'fco-cline-del', '×');
            del.type = 'button';
            del.title = L.remove || '';
            del.addEventListener('click', () => set(item, 0));
            row.appendChild(del);
            lines.appendChild(row);
        });
        total = Math.round(total * 100) / 100;
        if (!order.length) lines.appendChild(el('div', 'fco-cart-empty', L.cartEmpty || ''));
        st.units.textContent = units ? fmt(L.units, units) : '';
        st.total.textContent = money(total);
        const cash = Number(p.cash) || 0;
        st.cash.textContent = money(cash);
        const enough = cash + 0.0001 >= total;
        st.cash.classList.toggle('bad', !enough);
        st.warn.textContent = order.length && !enough ? (L.noCash || '') : '';
        st.buy.disabled = !order.length || !enough;
        st.order = order;
        st.totalValue = total;
        st.unitsValue = units;
    }

    C('fco-shop', {
        render(p, c) {
            const L = p.labels || {};
            const box = el('div', 'fco-shop fco-items');
            const main = el('div', 'fco-shop-main');
            const search = el('input', 'fco-shop-search');
            search.type = 'text';
            search.placeholder = L.search || '';
            search.spellcheck = false;
            const grid = el('div', 'fco-shop-grid');
            main.append(search, grid);

            const side = el('div', 'fco-cart');
            const head = el('div', 'fco-cart-head');
            const units = el('small');
            head.append(el('h3', '', L.cart || ''), units);
            const lines = el('div', 'fco-cart-lines');
            const foot = el('div', 'fco-cart-foot');
            const rowT = el('div', 'fco-cart-row total');
            const total = el('b');
            rowT.append(el('span', '', L.total || ''), total);
            const rowC = el('div', 'fco-cart-row');
            const cash = el('b', 'fco-cash');
            rowC.append(el('span', '', L.cash || ''), cash);
            const warn = el('div', 'fco-cart-warn');
            const buy = el('button', 'btn main fco-buy', L.buy || '');
            buy.type = 'button';
            foot.append(rowT, rowC, warn, buy, el('div', 'fco-cart-note', L.note || ''));
            side.append(head, lines, foot);
            box.append(main, side);

            box._fco = { cart: new Map(), q: '', grid, lines, units, total, cash, warn, buy, order: [] };
            search.addEventListener('input', () => { box._fco.q = search.value; shopDraw(box, p); });
            buy.addEventListener('click', () => {
                const st = box._fco;
                if (!st.order.length) return;
                c.fire({ action: p.action, confirm: { title: L.confirmTitle, text: fmt(L.confirmText, money(st.totalValue), st.unitsValue), ok: L.pay, cancel: L.cancel } },
                    { value: st.order }, buy);
            });
            shopDraw(box, p);
            return box;
        },
        // live stock / cash from Lua: keeps the cart, but never more than what exists
        update(box, p) {
            const st = box._fco;
            if (!st) return;
            const products = list(p.products);
            let trimmed = false;
            if (p.clearCart) { st.cart.clear(); p.clearCart = false; }
            st.cart.forEach((n, item) => {
                const x = products.find((y) => y.item === item);
                const limit = x ? Math.min(x.quantity, Number(p.maxQty) || 100) : 0;
                if (limit < 1) { st.cart.delete(item); trimmed = true; } else if (n > limit) { st.cart.set(item, limit); trimmed = true; }
            });
            shopDraw(box, p);
            if (trimmed && p.labels && p.labels.adjusted && FKS.toast) FKS.toast(p.labels.adjusted, 'warning');
        },
    });

    /* ---------------------------------------------------------- fco-stock */
    C('fco-stock', {
        render(p, c) {
            const L = p.labels || {};
            const box = el('div', 'fco-stockbox fco-items');
            const colA = el('div', 'fco-col');
            const headA = el('div', 'fco-col-head');
            headA.append(el('h3', '', L.store || ''), el('small', '', L.storeCount || ''));
            const listA = el('div', 'fco-col-list');
            list(p.products).forEach((x) => {
                const r = el('div', `fco-srow${x.quantity < 1 ? ' out' : ''}`);
                r.appendChild(picture(x.img, 'fco-srow-img'));
                const mid = el('div', 'fco-srow-mid');
                const top = el('div', 'fco-srow-top');
                top.append(el('b', '', x.label), el('span', 'fco-price', money(x.price)));
                mid.append(top, el('small', '', x.sub || ''));
                const acts = el('div', 'fco-srow-acts');
                list(x.actions).forEach((a) => { const b = c.renderNode({ type: 'button', small: true, ...a }, c); if (b) acts.appendChild(b); });
                mid.appendChild(acts);
                r.appendChild(mid);
                listA.appendChild(r);
            });
            if (!list(p.products).length) listA.appendChild(el('div', 'fco-shop-empty', L.empty || ''));
            colA.append(headA, listA);

            const colB = el('div', 'fco-col');
            const headB = el('div', 'fco-col-head');
            headB.append(el('h3', '', L.inventory || ''));
            const search = el('input', 'fco-shop-search');
            search.type = 'text';
            search.placeholder = L.search || '';
            search.spellcheck = false;
            const listB = el('div', 'fco-col-list');
            const drawInv = () => {
                listB.innerHTML = '';
                const needle = search.value.trim().toLowerCase();
                const inv = list(p.inventory).filter((x) => !needle || x.label.toLowerCase().includes(needle) || x.name.toLowerCase().includes(needle));
                inv.forEach((x) => {
                    const r = el('div', 'fco-irow');
                    r.appendChild(picture(x.img, 'fco-srow-img'));
                    const mid = el('div', 'fco-srow-mid');
                    mid.append(el('b', '', x.label), el('small', '', x.sub || ''));
                    r.appendChild(mid);
                    if (x.action) { const b = c.renderNode({ type: 'button', small: true, ...x.action }, c); if (b) r.appendChild(b); }
                    listB.appendChild(r);
                });
                if (!inv.length) listB.appendChild(el('div', 'fco-shop-empty', list(p.inventory).length ? (L.noResults || '') : (L.emptyInv || '')));
            };
            search.addEventListener('input', drawInv);
            drawInv();
            colB.append(headB, search, listB);
            box.append(colA, colB);
            return box;
        },
    });

    FKS.extension(owner, {
        mount(a) {
            api = a;
            root = a.root;
            root.classList.add('fco-root');
        },
        messages: {
            'contract:show': (d) => contract(d),
            'bill:show': (d) => bill(d),
            'doc:hide': (d) => { if (current && (!d || !d.id || d.id === current.id)) hide(false); },
        },
        unmount() { clear(); },
    });
})();
