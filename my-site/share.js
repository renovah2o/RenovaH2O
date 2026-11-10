const siteFooter = document.querySelector("footer");

if (siteFooter) {
  fetch("/footer.html")
    .then(response => {
      if (!response.ok) {
        throw new Error(`No se pudo cargar footer.html: ${response.status}`);
      }

      return response.text();
    })
    .then(markup => {
      siteFooter.outerHTML = markup;
      const year = document.querySelector(".footer #year");

      if (year) {
        year.textContent = String(new Date().getFullYear());
      }
    })
    .catch(error => {
      console.error("Error al cargar el footer compartido.", error);
    });
}

function addShareOptions(section) {
  const grid = section.querySelector(".socials-grid");
  if (!grid || section.querySelector(".share-options")) return;

  const canonicalUrl = document.querySelector('link[rel="canonical"]')?.href || window.location.href;
  const pageUrl = new URL(canonicalUrl);
  pageUrl.hash = "";
  const title = document.title;

  const shareOptions = document.createElement("div");
  shareOptions.className = "share-options";

  const heading = document.createElement("h3");
  heading.textContent = "Comparte esta página";

  const links = document.createElement("div");
  links.className = "share-links";

  const addShareLink = (label, href, ariaLabel) => {
    const link = document.createElement("a");
    link.className = "share-link";
    link.href = href;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.textContent = label;
    link.setAttribute("aria-label", ariaLabel);
    links.append(link);
  };

  addShareLink(
    "WhatsApp",
    `https://wa.me/?text=${encodeURIComponent(`${title} ${pageUrl.href}`)}`,
    "Compartir esta página por WhatsApp"
  );
  addShareLink(
    "Facebook",
    `https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(pageUrl.href)}`,
    "Compartir esta página en Facebook"
  );
  addShareLink(
    "X",
    `https://twitter.com/intent/tweet?text=${encodeURIComponent(title)}&url=${encodeURIComponent(pageUrl.href)}`,
    "Compartir esta página en X"
  );

  const instagramButton = document.createElement("button");
  instagramButton.className = "share-link";
  instagramButton.type = "button";
  instagramButton.textContent = "Instagram";
  instagramButton.setAttribute("aria-label", "Copiar enlace para compartir esta página en Instagram");

  const status = document.createElement("p");
  status.className = "share-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");

  instagramButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(pageUrl.href);
      status.textContent = "Enlace copiado. Abre Instagram y pégalo donde quieras compartirlo.";
    } catch {
      status.textContent = "No se pudo copiar el enlace automáticamente. Copia la dirección de esta página desde la barra del navegador.";
    }
  });

  links.append(instagramButton);
  shareOptions.append(heading, links, status);
  grid.after(shareOptions);
}

if (!document.body.hasAttribute("data-no-social")) {
  fetch("/social.html")
    .then(response => {
      if (!response.ok) {
        throw new Error(`No se pudo cargar social.html: ${response.status}`);
      }

      return response.text();
    })
    .then(markup => {
      const template = document.createElement("template");
      template.innerHTML = markup;
      const styles = template.content.querySelector("style");
      const socialSection = template.content.querySelector("#site-socials");

      if (!socialSection) {
        throw new Error("social.html no contiene la sección #site-socials.");
      }

      if (styles) {
        document.head.append(styles);
      }

      const existingSection = document.querySelector(".socials");

      if (existingSection) {
        existingSection.replaceWith(socialSection);
      } else {
        const footer = document.querySelector("footer");

        if (footer) {
          footer.before(socialSection);
        } else {
          document.body.append(socialSection);
        }
      }

      addShareOptions(socialSection);
    })
    .catch(error => {
      console.error("Error al cargar la sección social compartida.", error);
    });
}

// Compartir productos: usa el menú nativo de iOS/Android y conserva un enlace directo al producto.
(() => {
  const shareStyle = document.createElement("style");
  shareStyle.textContent = `
    .product-share-button{
      position:absolute;top:14px;right:14px;z-index:5;
      display:grid;place-items:center;width:38px;height:38px;
      padding:0;border:1px solid #0071e3;border-radius:50%;
      background:#0071e3;color:#fff;
      box-shadow:0 3px 12px rgba(0,113,227,.28);cursor:pointer;
      -webkit-tap-highlight-color:transparent;transition:transform .18s ease,background .18s ease,box-shadow .18s ease;
    }
    .product-share-button:hover{transform:translateY(-2px);background:#005bbf;border-color:#005bbf;box-shadow:0 5px 16px rgba(0,91,191,.32)}
    .product-share-button:focus-visible{outline:3px solid rgba(0,113,227,.35);outline-offset:3px}
    .product-share-button svg{width:18px;height:18px;display:block}
    .product-share-status{
      position:absolute;left:12px;right:58px;top:14px;z-index:6;
      width:max-content;max-width:calc(100% - 82px);margin:0;padding:7px 10px;
      border-radius:9px;background:#17191d;color:#fff;font-size:12px;line-height:1.4;
      box-shadow:0 3px 12px rgba(0,0,0,.14)
    }
    @media(prefers-reduced-motion:reduce){.product-share-button{transition:none}}
  `;
  document.head.append(shareStyle);

  const shareIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="18" cy="5" r="3"></circle><circle cx="6" cy="12" r="3"></circle><circle cx="18" cy="19" r="3"></circle><path d="m8.7 10.7 6.6-4.4M8.7 13.3l6.6 4.4"></path></svg>`;

  function initializeProductSharing() {
    document.querySelectorAll("article").forEach(card => {
      const addButton = card.querySelector(".add-to-cart[data-sku]");
      if (!addButton || card.querySelector(".product-share-button")) return;

      const sku = addButton.dataset.sku;
      const title = card.querySelector("h3")?.textContent.trim() ||
        card.querySelector("h2")?.textContent.trim() || "Producto RenovaH2O";
      const productId = `producto-${sku.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
      card.id = card.id || productId;
      card.style.position = card.style.position || "relative";
      card.style.scrollMarginTop = "84px";

      const button = document.createElement("button");
      button.className = "product-share-button";
      button.type = "button";
      button.innerHTML = shareIcon;
      button.setAttribute("aria-label", `Compartir ${title}`);
      button.title = "Compartir producto";

      const status = document.createElement("p");
      status.className = "product-share-status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      status.hidden = true;

      button.addEventListener("click", async () => {
        const url = new URL(`/compartir/${encodeURIComponent(sku)}`, window.location.origin);

        const description = card.querySelector("p")?.textContent.trim() || "";
        const price = card.querySelector(".package-price, .price, .price-row")?.textContent.trim() || "";
        const message = [title, price, description, url.href].filter(Boolean).join("\n");

        try {
          if (navigator.share) {
            await navigator.share({ title, text: [price, description].filter(Boolean).join("\n"), url: url.href });
          } else {
            const whatsappUrl = `https://wa.me/?text=${encodeURIComponent(message)}`;
            const popup = window.open(whatsappUrl, "_blank", "noopener,noreferrer");
            if (!popup) {
              await navigator.clipboard.writeText(message);
              status.textContent = "Enlace y detalles copiados para compartir.";
              status.hidden = false;
            }
          }
        } catch (error) {
          if (error?.name === "AbortError") return;
          try {
            await navigator.clipboard.writeText(message);
            status.textContent = "Enlace y detalles copiados para compartir.";
          } catch {
            status.textContent = "No se pudo abrir el menú para compartir. Copia el enlace de esta página.";
          }
          status.hidden = false;
        }
      });

      card.append(button, status);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializeProductSharing, { once: true });
  } else {
    initializeProductSharing();
  }
})();

