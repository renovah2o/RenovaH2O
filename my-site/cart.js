(function () {
  const storageKey = "renovah2o-cart-v1";
  const products = {
    "rental-35": {
      name: "Hidrolavadora 4000 PSI · 3.5 GPM (hasta 24 horas)",
      image: "/Images/alq-3.5%20GPM%20pressure%20washer.jpg",
      category: "alquileres",
      kind: "machine",
      unitAmount: 5000,
      minimum: 1,
      maximum: 2
    },
    "rental-23": {
      name: "Hidrolavadora 2700 PSI · 2.3 GPM (hasta 24 horas)",
      image: "/Images/alq-2.3%20gpm%20pressure%20washer.jpg",
      category: "alquileres",
      kind: "machine",
      unitAmount: 4000,
      minimum: 1,
      maximum: 2
    },
    "rental-surface-cleaner": {
      name: "Disco de hidrolavado de 20 pulgadas",
      image: "/Images/alq-disco.jpg",
      category: "alquileres",
      kind: "accessory",
      unitAmount: 5000,
      minimum: 1,
      maximum: 2
    },
    "rental-turbo-nozzle": {
      name: "Turbo nozzle",
      image: "/Images/alq-turbo.jpg",
      category: "alquileres",
      kind: "accessory",
      unitAmount: 1000,
      minimum: 1,
      maximum: 2
    },
    "rental-broom": {
      name: "Broom de 24 pulgadas",
      image: "/Images/alq-broom.jpg",
      category: "alquileres",
      kind: "accessory",
      unitAmount: 3000,
      minimum: 1,
      maximum: 2
    },
    "rental-extra-hose": {
      name: "Manguera adicional de 50 pies",
      image: "/Images/alq-Manguera.jpg",
      category: "alquileres",
      kind: "accessory",
      unitAmount: 3000,
      minimum: 1,
      maximum: 2
    },
    "residential-holiday-promo": {
      name: "Promoción navideña de hidrolavado residencial · hasta 50 m²",
      image: "/Images/promo-navidad-renovah2o.png",
      category: "residencial",
      kind: "area",
      pricing: "promo",
      baseAmount: 7425,
      includedMeters: 50,
      additionalMeterAmount: 0,
      minimum: 1,
      maximum: 1,
      saleEndsOn: "2026-12-31"
    },
    "residential-65-100": {
      name: "Hidrolavado residencial · 65 a 100 m²",
      image: "/Images/100m2.jpeg",
      category: "residencial",
      kind: "area",
      unitAmount: 200,
      minimum: 65,
      maximum: 100
    },
    "residential-115-500": {
      name: "Hidrolavado residencial · 115 a 500 m²",
      image: "/Images/500m2.jpeg",
      category: "residencial",
      kind: "area",
      unitAmount: 175,
      minimum: 115,
      maximum: 500
    }
  };

  function panamaDate(date = new Date()) {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Panama",
      year: "numeric",
      month: "2-digit",
      day: "2-digit"
    }).formatToParts(date);
    const part = name => parts.find(entry => entry.type === name).value;
    return `${part("year")}-${part("month")}-${part("day")}`;
  }

  function priceFor(product, quantity) {
    if (product.pricing === "promo") {
      return product.baseAmount + Math.max(quantity - product.includedMeters, 0) * product.additionalMeterAmount;
    }
    return product.unitAmount * quantity;
  }

  function formatCurrency(cents) {
    return new Intl.NumberFormat("es-PA", { style: "currency", currency: "USD" }).format(cents / 100);
  }

  function updatePriceDisplays() {
    document.querySelectorAll("[data-price-for]").forEach(output => {
      const input = document.getElementById(output.dataset.priceFor);
      const button = document.querySelector(`.add-to-cart[data-quantity-input="#${input?.id}"]`);
      const product = products[button?.dataset.sku];
      if (!input || !product) return;
      const quantity = Number(input.value);
      output.textContent = Number.isInteger(quantity) && quantity >= product.minimum && quantity <= product.maximum
        ? formatCurrency(priceFor(product, quantity))
        : "Selecciona un metraje válido";
    });
  }

  function readItems() {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return [];

    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      throw new Error("No se pudo leer el carrito guardado. Borra los datos del carrito e inténtalo otra vez.");
    }

    const normalized = parsed.map(item =>
      item?.sku === "residential-holiday-promo" ? { ...item, quantity: 1 } : item
    );
    if (JSON.stringify(normalized) !== JSON.stringify(parsed)) {
      window.localStorage.setItem(storageKey, JSON.stringify(normalized));
    }

    if (normalized.some(item =>
      !item ||
      typeof item.sku !== "string" ||
      !products[item.sku] ||
      !Number.isInteger(item.quantity) ||
      item.quantity < products[item.sku].minimum ||
      item.quantity > products[item.sku].maximum
    )) {
      throw new Error("El carrito contiene un producto o metraje inválido. Quita los datos antiguos y vuelve a agregar tus productos.");
    }

    return normalized;
  }

  function saveItems(items) {
    window.localStorage.setItem(storageKey, JSON.stringify(items));
    window.dispatchEvent(new CustomEvent("renovah2o-cart-changed"));
  }

  function showFeedback(message) {
    let feedback = document.querySelector("#cart-feedback");
    if (!feedback) {
      feedback = document.createElement("p");
      feedback.id = "cart-feedback";
      feedback.setAttribute("role", "status");
      feedback.setAttribute("aria-live", "polite");
      feedback.style.cssText = "position:fixed;z-index:2000;left:50%;bottom:22px;transform:translateX(-50%);max-width:min(90vw,520px);padding:12px 18px;border-radius:12px;background:#111;color:#fff;box-shadow:0 10px 35px #0003;text-align:center";
      document.body.append(feedback);
    }
    feedback.textContent = message;
    feedback.hidden = false;
    window.clearTimeout(showFeedback.timeoutId);
    showFeedback.timeoutId = window.setTimeout(() => {
      feedback.hidden = true;
    }, 3500);
  }

  function addProduct(button) {
    const sku = button.dataset.sku;
    const product = products[sku];
    if (!product) throw new Error("El producto seleccionado no está disponible.");

    const input = button.dataset.quantityInput
      ? document.querySelector(button.dataset.quantityInput)
      : null;
    const quantity = input ? Number(input.value) : 1;
    if (!Number.isInteger(quantity) || quantity < product.minimum || quantity > product.maximum) {
      throw new Error(`Selecciona una cantidad entre ${product.minimum} y ${product.maximum}.`);
    }

    if (product.saleEndsOn && panamaDate() > product.saleEndsOn) {
      throw new Error("Esta promoción ya venció.");
    }

    const items = readItems();
    const existingCategory = items.length ? products[items[0].sku].category : null;
    if (existingCategory && existingCategory !== product.category) {
      throw new Error("Para iniciar, cada orden debe ser solo de alquiler o solo residencial. Completa o vacía el carrito antes de agregar otra categoría.");
    }

    if (product.kind === "area" && items.some(item => item.sku !== sku && products[item.sku].kind === "area")) {
      throw new Error("El carrito puede incluir un solo paquete de superficie residencial.");
    }

    const existing = items.find(item => item.sku === sku);
    const updatedQuantity = (existing?.quantity ?? 0) + quantity;
    if (updatedQuantity > product.maximum) {
      throw new Error(`Solo puedes agregar hasta ${product.maximum} unidad(es) de este producto por orden.`);
    }

    const machineCount = items.reduce((total, item) => {
      return total + (products[item.sku].kind === "machine" ? item.quantity : 0);
    }, 0) + (product.kind === "machine" ? quantity : 0);
    if (product.kind === "machine" && machineCount > 2) {
      throw new Error("Solo hay 2 hidrolavadoras disponibles para alquiler por orden.");
    }

    if (existing && product.kind === "area") {
      existing.quantity = quantity;
    } else if (existing) {
      existing.quantity = updatedQuantity;
    } else {
      items.push({ sku, quantity });
    }

    saveItems(items);
    showFeedback(`${product.name} se agregó al carrito.`);
    button.textContent = "Agregado";
    window.setTimeout(() => {
      button.textContent = button.dataset.originalText || "Agregar al carrito";
    }, 1800);
  }

  function initializeProductButtons() {
    document.querySelectorAll(".add-to-cart[data-sku]").forEach(button => {
      button.dataset.originalText = button.textContent.trim();
      button.addEventListener("click", () => {
        try {
          addProduct(button);
        } catch (error) {
          showFeedback(error.message);
        }
      });
    });

    document.querySelectorAll("[data-price-quantity]").forEach(input => {
      input.addEventListener("input", updatePriceDisplays);
    });
    updatePriceDisplays();
  }

  window.RenovaCart = {
    products,
    readItems,
    saveItems,
    storageKey
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initializeProductButtons, { once: true });
  } else {
    initializeProductButtons();
  }
})();
