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
