const PRODUCTS = {
  "rental-35": {
    title: "Hidrolavadora profesional 4000 PSI · 3.5 GPM",
    description: "Alquiler de hidrolavadora profesional de 4000 PSI y 3.5 GPM, con accesorios, orientación de uso y entrega coordinada.",
    image: "/Images/alq-3.5%20GPM%20pressure%20washer.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "rental-23": {
    title: "Hidrolavadora 2700 PSI · 2.3 GPM",
    description: "Alquiler de hidrolavadora de 2700 PSI y 2.3 GPM para proyectos de limpieza y mantenimiento.",
    image: "/Images/alq-2.3%20gpm%20pressure%20washer.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "rental-surface-cleaner": {
    title: "Disco de hidrolavado de 20 pulgadas",
    description: "Accesorio profesional para lograr una limpieza más uniforme de superficies amplias. Disponible en alquiler junto con una hidrolavadora.",
    image: "/Images/alq-disco.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "rental-turbo-nozzle": {
    title: "Turbo nozzle para hidrolavadora",
    description: "Accesorio de limpieza de alta potencia disponible en alquiler junto con una hidrolavadora RenovaH2O.",
    image: "/Images/alq-turbo.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "rental-broom": {
    title: "Broom de 24 pulgadas",
    description: "Accesorio de limpieza de superficies para equipos de hidrolavado, disponible en alquiler junto con una hidrolavadora.",
    image: "/Images/alq-broom.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "rental-extra-hose": {
    title: "Manguera adicional de 50 pies",
    description: "Manguera adicional para ampliar el alcance de trabajo de tu equipo de hidrolavado.",
    image: "/Images/alq-Manguera.jpg",
    page: "/alquiler-de-hidrolavadoras-panama"
  },
  "residential-holiday-promo": {
    title: "Promoción de hidrolavado residencial en Panamá",
    description: "Promoción RenovaH2O para hidrolavado residencial de superficies exteriores de 10 a 50 m². Válida hasta el 31 de diciembre de 2026.",
    image: "/Images/og-december.webp",
    page: "/limpieza-de-pisos-panama"
  },
  "residential-65-100": {
    title: "Hidrolavado residencial · 65 a 100 m²",
    description: "Servicio profesional de hidrolavado para patios, terrazas, aceras y superficies residenciales de 65 a 100 m².",
    image: "/Images/100m2.jpeg",
    page: "/limpieza-de-pisos-panama"
  },
  "residential-115-500": {
    title: "Hidrolavado residencial · 115 a 500 m²",
    description: "Servicio profesional de hidrolavado para superficies residenciales de 115 a 500 m².",
    image: "/Images/500m2.jpeg",
    page: "/limpieza-de-pisos-panama"
  },
  "commercial-115-500": {
    title: "Hidrolavado comercial · 115 a 500 m²",
    description: "Servicio de hidrolavado para escuelas, iglesias, pequeños estacionamientos y otras instalaciones comerciales de 115 a 500 m².",
    image: "/Images/115.jpg",
    page: "/limpieza-de-estacionamientos-panama"
  },
  "commercial-600-1000": {
    title: "Hidrolavado comercial · 600 a 1,000 m²",
    description: "Servicio profesional de hidrolavado para comercios, restaurantes, plazas y establecimientos de 600 a 1,000 m².",
    image: "/Images/600.jpg",
    page: "/limpieza-de-estacionamientos-panama"
  },
  "commercial-1250-5000": {
    title: "Hidrolavado comercial · 1,250 a 5,000 m²",
    description: "Servicio profesional de hidrolavado para PH y grandes superficies comerciales de 1,250 a 5,000 m².",
    image: "/Images/1250.jpg",
    page: "/limpieza-de-estacionamientos-panama"
  }
};

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  })[character]);
}

function withSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Frame-Options", "DENY");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  headers.set("Permissions-Policy", "geolocation=(), microphone=(), camera=()");
  headers.set("Strict-Transport-Security", "max-age=31536000");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

function sharePage(product, slug, origin) {
  const title = product.title;
  const description = product.description;
  const image = new URL(product.image, origin).href;
  const canonical = new URL("/compartir/" + encodeURIComponent(slug), origin).href;
  const destination = new URL(product.page + "#producto-" + slug, origin).href;

  const html = `<!doctype html>
<html lang="es-PA">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,follow">
<title>${escapeHtml(title)} | RenovaH2O</title>
<meta name="description" content="${escapeHtml(description)}">
<link rel="canonical" href="${escapeHtml(canonical)}">
<meta property="og:type" content="product">
<meta property="og:locale" content="es_PA">
<meta property="og:site_name" content="RenovaH2O">
<meta property="og:title" content="${escapeHtml(title)}">
<meta property="og:description" content="${escapeHtml(description)}">
<meta property="og:url" content="${escapeHtml(canonical)}">
<meta property="og:image" content="${escapeHtml(image)}">
<meta property="og:image:secure_url" content="${escapeHtml(image)}">
<meta property="og:image:alt" content="${escapeHtml(title)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${escapeHtml(title)}">
<meta name="twitter:description" content="${escapeHtml(description)}">
<meta name="twitter:image" content="${escapeHtml(image)}">
<meta name="theme-color" content="#050505">
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#f5f5f7;color:#1d1d1f;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.card{width:min(100%,520px);padding:28px;border:1px solid #e1e1e5;border-radius:22px;background:#fff;text-align:center;box-shadow:0 12px 40px #0000000d}img{display:block;width:100%;max-height:300px;object-fit:contain;border-radius:14px;margin:0 auto 22px}h1{font-size:24px;line-height:1.15;letter-spacing:-.04em;margin:0 0 10px}p{color:#666;margin:0 0 22px}a{display:inline-block;padding:12px 22px;border-radius:999px;background:#0071e3;color:#fff;text-decoration:none;font-weight:650}
</style>
<script>window.location.replace(${JSON.stringify(destination)});</script>
</head>
<body>
<main class="card">
<img src="${escapeHtml(image)}" alt="${escapeHtml(title)}">
<h1>${escapeHtml(title)}</h1>
<p>${escapeHtml(description)}</p>
<a href="${escapeHtml(destination)}">Ver producto en RenovaH2O</a>
</main>
</body>
</html>`;

  return withSecurityHeaders(new Response(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300, s-maxage=3600"
    }
  }));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const productRoute = url.pathname.match(/^\/tienda\/([a-z0-9-]+)\/?$/i);
    if (productRoute) {
      const productUrl = new URL("/producto.html", url);
      productUrl.searchParams.set("slug", productRoute[1]);
      return env.ASSETS.fetch(new Request(productUrl, request));
    }
    const match = url.pathname.match(/^\/compartir\/([a-z0-9-]+)\/?$/i);

    if (match) {
      const slug = match[1].toLowerCase();
      const product = PRODUCTS[slug];
      if (!product) {
        return withSecurityHeaders(new Response("Producto no encontrado", {
          status: 404,
          headers: { "Content-Type": "text/plain; charset=utf-8" }
        }));
      }
      return sharePage(product, slug, url.origin);
    }

    return env.ASSETS.fetch(request);
  }
};
