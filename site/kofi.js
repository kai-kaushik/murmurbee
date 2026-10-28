/* Ko-fi "Buy me a coffee" button on every page: a pill at bottom left on desktop, a round cup at bottom right on
 * phones. Loaded after the page so it never slows first paint. */
addEventListener('load', function () {
  var k = document.createElement('script');
  k.src = 'https://storage.ko-fi.com/cdn/scripts/overlay-widget.js';
  k.onload = function () {
    kofiWidgetOverlay.draw('kaikaushik', {
      'type': 'floating-chat',
      'floating-chat.donateButton.text': 'Buy me a coffee',
      'floating-chat.donateButton.background-color': '#F8BE34',
      'floating-chat.donateButton.text-color': '#16130F'
    });
    // Ko-fi draws the button in a fixed 195px frame, which cuts off the right end of a wider
    // button. Once it renders, size the frame to the button (via a stylesheet rule, since Ko-fi
    // rewrites the frame's inline style).
    // On phones Ko-fi uses a separate frame; there the pill becomes a round cup-only button, bottom right.
    var tries = 0, sized = false, cupped = false, fit = setInterval(function () {
      var f = document.querySelector('.floatingchat-container'), m = document.querySelector('.floatingchat-container-mobi'), btn, doc;
      try { btn = f && f.contentDocument.querySelector('.floatingchat-donate-button'); } catch (e) {}
      if (!sized && btn && btn.scrollWidth) { document.documentElement.style.setProperty('--kofi-w', (btn.scrollWidth + 12) + 'px'); sized = true; }
      try { doc = m && m.contentDocument; } catch (e) {}
      if (!cupped && doc && doc.querySelector('.floatingchat-donate-button')) {
        var st = doc.createElement('style');
        st.textContent = '.floatingchat-donate-button{width:46px!important;padding:0!important;justify-content:center!important}' +
          '.floatingchat-donate-button span{display:none!important}.floatingchat-donate-button img{width:28px!important;height:auto!important;margin:0!important}';
        doc.head.appendChild(st);
        document.documentElement.classList.add('kofi-cup');
        cupped = true;
      }
      if ((sized && cupped) || ++tries > 40) clearInterval(fit);
    }, 150);
  };
  document.body.appendChild(k);
});
