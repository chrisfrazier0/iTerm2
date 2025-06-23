;(function() {
    'use strict';
    const handlerName   = 'iTermOpenPasswordManager';
    const sessionSecret = "{{SECRET}}";
    console.log("password button running");
    let activeField = null;
    let activeType  = null; // 'password' or 'username'

    // create the floating button once
    const btn = document.createElement('button');
    btn.type            = 'button';
    btn.tabIndex        = -1;
    btn.setAttribute('aria-label', 'Open Password Manager');
    Object.assign(btn.style, {
        position:    'absolute',
        display:     'none',
        boxSizing:   'border-box',
        zIndex:      '2147483647',
        borderRadius:'4px',
        border:      '1px solid rgba(0,0,0,0.2)',
        background:  '#fff',
        cursor:      'pointer',
        fontSize:    '1em',
        lineHeight:  '1',
        display:     'flex',
        alignItems:  'center',
        justifyContent:'center',
        padding:     '0'
    });
    btn.addEventListener('mousedown', e => e.preventDefault());
    document.body.appendChild(btn);

    function updateBtnTheme() {
      if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
        btn.style.backgroundColor = '#2c2c2e';
        btn.style.border          = '1px solid rgba(255,255,255,0.3)';
        btn.style.color           = '#fff';
      } else {
        btn.style.backgroundColor = '#fff';
        btn.style.border          = '1px solid rgba(0,0,0,0.2)';
        btn.style.color           = '#000';
      }
    }
    updateBtnTheme();
    window.matchMedia('(prefers-color-scheme: dark)')
          .addEventListener('change', updateBtnTheme);

    const findNextPasswordField = function() {
        const current = document.activeElement;
        if (!(current instanceof HTMLElement)) {
            return;
        }

        const currentRect = current.getBoundingClientRect();

        // collect all visible, enabled password inputs
        const passwords = Array.from(
            document.querySelectorAll('input[type="password"]:not([disabled])')
        ).filter(el => el.offsetParent !== null);

        let closest = null;
        let minDistance = Infinity;

        for (const el of passwords) {
            const r = el.getBoundingClientRect();
            // only consider those positioned below the current element
            if (r.top > currentRect.bottom) {
                const distance = r.top - currentRect.bottom;
                if (distance < minDistance) {
                    minDistance = distance;
                    closest = el;
                }
            }
        }
        return closest;
    }

    // on click, notify native
    btn.addEventListener('click', e => {
        e.preventDefault();
        if (!activeField) return;
        const msgType = activeType === 'username' ? 'openUser' : 'openPassword';

        let nextPasswordFieldId = null;
        if (activeType === 'username') {
            const nextField = findNextPasswordField();
            nextPasswordFieldId = nextField
                ? nextField.id
                : null;
        }

        window.webkit.messageHandlers[handlerName].postMessage({
            type:          msgType,
            sessionSecret,
            fieldName:     activeField.name || null,
            nextPasswordFieldId: nextPasswordFieldId
        });
    });

    function updateButton() {
        if (!activeField) {
            btn.style.display = 'none';
            return;
        }

        const r         = activeField.getBoundingClientRect();
        const baseLeft  = window.scrollX + r.right - r.height;
        const minLeft   = window.scrollX + r.left;

        // choose emoji based on field type
        const emoji     = activeType === 'username' ? '👤' : '🔑';
        btn.textContent = emoji;
        btn.title       = 'Open Password Manager';

        btn.setAttribute('aria-label', btn.title);

        // measure glyph size
        const meas = document.createElement('span');
        Object.assign(meas.style, {
            position: 'absolute',
            visibility: 'hidden',
            font: getComputedStyle(btn).font
        });
        meas.textContent = emoji;
        document.body.appendChild(meas);
        const dim  = meas.getBoundingClientRect();
        document.body.removeChild(meas);
        const keyDim = Math.max(dim.width, dim.height);
        let side     = Math.min(r.height, keyDim * 1.5);

        // position and size
        btn.style.width   = `${side}px`;
        btn.style.height  = `${side}px`;
        btn.style.top     = `${window.scrollY + r.top + (r.height - side) / 2}px`;
        btn.style.left    = `${baseLeft}px`;
        btn.style.display = 'flex';

        // overlap detection (same as before)…
        const btnRect = btn.getBoundingClientRect();
        const step    = btnRect.height / 4;
        const samples = [
            { x: btnRect.right - 1, y: btnRect.top + step },
            { x: btnRect.right - 1, y: btnRect.top + 2*step },
            { x: btnRect.right - 1, y: btnRect.top + 3*step },
            { x: btnRect.left + btnRect.width/2, y: btnRect.top + btnRect.height/2 }
        ];
        const iz     = parseInt(getComputedStyle(activeField).zIndex) || 0;
        let overlapElRect = null;

        for (const {x,y} of samples) {
            for (const el of document.elementsFromPoint(x,y)) {
                if (el === btn || el === activeField) continue;
                const er = el.getBoundingClientRect();
                if (er.left   < r.left   ||
                    er.right  > r.right  ||
                    er.top    < r.top    ||
                    er.bottom > r.bottom) {
                    continue;
                }
                overlapElRect = er;
                break;
            }
            if (overlapElRect) break;
        }

        let newLeft = baseLeft;
        if (overlapElRect) {
            const overlap = btnRect.right - overlapElRect.left + 2;
            const maxShift= Math.min(32, baseLeft - minLeft);
            const shift   = Math.min(overlap, maxShift);
            newLeft        = baseLeft - shift;
        }
        newLeft = Math.max(newLeft, window.scrollX);
        btn.style.left = `${newLeft}px`;
    }

    // show on focusin, hide otherwise
    // replace your focusin listener with this:
    document.addEventListener('focusin', e => {
        const t = e.target;
        // ignore focus on our button
        if (t === btn) {
            return;
        }
        if (t.tagName === 'INPUT' &&
            t.offsetParent !== null && ((t.type === 'password') ||
                                        (t.getAttribute('autocomplete') === 'username'))) {
            activeField = t;
            activeType  = t.type === 'password' ? 'password' : 'username';
            updateButton();
        } else {
            // if focus moved anywhere else *except* our button, hide
            activeField = null;
            btn.style.display = 'none';
        }
    });

    document.addEventListener('scroll', updateButton, true);
    window.addEventListener('resize', updateButton);
})();
