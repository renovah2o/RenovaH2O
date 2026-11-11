import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cfg = window.RENOVA_SUPABASE_CONFIG;

if (cfg?.url && cfg?.publishableKey) {
  const sb = createClient(cfg.url, cfg.publishableKey);
  const $ = selector => document.querySelector(selector);

  const tile = $("#admin-catalog-tile");
  const list = $("#catalog-admin-list");
  const form = $("#catalog-product-form");
  const editor = $("#catalog-admin-editor");
  const status = $("#catalog-editor-status");
  const feedback = $("#catalog-admin-feedback");
  const summary = $("#catalog-admin-summary");
  const search = $("#catalog-search");
  const filter = $("#catalog-filter");

  let products = [];
  let editing = null;
  let photos = [];

  const esc = value => String(value ?? "").replace(/[&<>"']/g, char => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  }[char]));

  const lines = value => value.split("\n").map(item => item.trim()).filter(Boolean);

  function showEditor() {
    editor.hidden = false;
    editor.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function reset() {
    form.reset();
    $("#catalog-original-sku").value = "";
    $("#catalog-editor-heading").textContent = "Nuevo producto o servicio";
    $("#catalog-save").textContent = "Guardar producto o servicio";
    $("#catalog-active").checked = true;
    $("#catalog-sort").value = "100";
    $("#catalog-min").value = "1";
    $("#catalog-max").value = "1";
    $("#catalog-photo-preview").replaceChildren();
    $("#catalog-photos").value = "";
    editing = null;
    photos = [];
    status.textContent = "";
    editor.hidden = true;
  }

  function render() {
    const query = (search.value || "").trim().toLocaleLowerCase("es");
    const selectedFilter = filter.value;

    const visibleProducts = products.filter(product => {
      const matchesQuery = !query || [
        product.title,
        product.slug,
        product.sku,
        product.category,
        product.tag,
        product.short_description
      ].some(value => String(value ?? "").toLocaleLowerCase("es").includes(query));

      const matchesFilter =
        selectedFilter === "all" ||
        (selectedFilter === "active" && product.active) ||
        (selectedFilter === "inactive" && !product.active) ||
        product.category === selectedFilter;

      return matchesQuery && matchesFilter;
    });

    const published = products.filter(product => product.active).length;
    const hiddenCount = products.length - published;
    summary.textContent = products.length
      ? `${products.length} registros · ${published} publicados · ${hiddenCount} ocultos`
      : "Todavía no hay productos o servicios en el inventario.";

    if (!visibleProducts.length) {
      list.innerHTML = products.length
        ? '<p class="empty-state">No se encontraron registros con esa búsqueda o filtro.</p>'
        : '<p class="empty-state">El inventario está vacío. Usa “Agregar producto o servicio” para crear el primer registro.</p>';
      return;
    }

    list.innerHTML = visibleProducts.map(product => `
      <article class="catalog-admin-item">
        <img src="${esc(product.images?.[0] || "")}" alt="" loading="lazy">
        <div class="meta">
          <strong>${esc(product.title)}</strong>
          <small>/tienda/${esc(product.slug)} · ${product.active ? "Publicado" : "Oculto"} · ${esc(product.category)}</small>
          <div>${product.tag ? `<span class="catalog-status-pill">${esc(product.tag)}</span>` : ""}</div>
        </div>
        <div class="actions">
          <button type="button" data-edit="${esc(product.sku)}">Editar</button>
          <button type="button" data-toggle="${esc(product.sku)}">${product.active ? "Ocultar" : "Publicar"}</button>
          <button type="button" data-delete="${esc(product.sku)}">Eliminar</button>
          <a href="/tienda/${encodeURIComponent(product.slug)}" target="_blank" rel="noopener">Ver página ↗</a>
        </div>
      </article>
    `).join("");
  }

  async function load() {
    list.textContent = "Cargando inventario…";
    summary.textContent = "Consultando productos y servicios…";

    const { data, error } = await sb
      .from("catalog_products")
      .select("*")
      .order("sort_order")
      .order("title");

    if (error) {
      list.textContent = "No se pudo cargar el inventario: " + error.message;
      summary.textContent = "No fue posible consultar el inventario.";
      return;
    }

    products = data || [];
    render();
  }

  async function edit(product) {
    editing = product;
    photos = [...(product.images || [])];

    $("#catalog-original-sku").value = product.sku;
    $("#catalog-title").value = product.title || "";
    $("#catalog-slug").value = product.slug || "";
    $("#catalog-category").value = product.category || "residencial";
    $("#catalog-badge").value = product.tag || "";
    $("#catalog-short").value = product.short_description || "";
    $("#catalog-description").value = product.description || "";
    $("#catalog-includes").value = (product.included_items || []).join("\n");
    $("#catalog-conditions").value = (product.conditions || []).join("\n");
    $("#catalog-availability").value = product.availability_note || "";
    $("#catalog-price-label").value = product.price_label || "";
    $("#catalog-sort").value = product.sort_order ?? 100;
    $("#catalog-active").checked = Boolean(product.active);

    $("#catalog-photo-preview").innerHTML = photos.map((url, index) => `
      <span class="catalog-photo-thumb">
        <img src="${esc(url)}" alt="Foto actual ${index + 1}">
        <button type="button" data-photo-remove="${index}" aria-label="Quitar foto">×</button>
      </span>
    `).join("");

    $("#catalog-editor-heading").textContent = "Editar: " + product.title;
    $("#catalog-save").textContent = "Guardar cambios";

    const { data: checkoutProduct } = await sb
      .from("checkout_products")
      .select("*")
      .eq("sku", product.sku)
      .maybeSingle();

    $("#catalog-bookable").checked = Boolean(checkoutProduct?.active);
    $("#catalog-price").value = checkoutProduct ? checkoutProduct.unit_amount / 100 : "";
    $("#catalog-kind").value = checkoutProduct?.product_kind || "area";
    $("#catalog-min").value = checkoutProduct?.min_quantity || 1;
    $("#catalog-max").value = checkoutProduct?.max_quantity || 1;

    status.textContent = "Editando un registro existente. Los cambios se guardarán sobre este mismo producto.";
    showEditor();
  }

  $("#catalog-add-new").addEventListener("click", () => {
    reset();
    $("#catalog-editor-heading").textContent = "Nuevo producto o servicio";
    $("#catalog-save").textContent = "Guardar producto o servicio";
    showEditor();
    $("#catalog-title").focus({ preventScroll: true });
  });

  search.addEventListener("input", render);
  filter.addEventListener("change", render);

  $("#catalog-photo-preview").addEventListener("click", event => {
    const button = event.target.closest("[data-photo-remove]");
    if (!button) return;

    photos.splice(Number(button.dataset.photoRemove), 1);
    $("#catalog-photo-preview").innerHTML = photos.map((url, index) => `
      <span class="catalog-photo-thumb">
        <img src="${esc(url)}" alt="Foto actual ${index + 1}">
        <button type="button" data-photo-remove="${index}" aria-label="Quitar foto">×</button>
      </span>
    `).join("");
  });

  list.addEventListener("click", async event => {
    const button = event.target.closest("button");
    if (!button) return;

    const product = products.find(item =>
      item.sku === button.dataset.edit ||
      item.sku === button.dataset.toggle ||
      item.sku === button.dataset.delete
    );
    if (!product) return;

    if (button.dataset.edit) {
      await edit(product);
      return;
    }

    if (button.dataset.toggle) {
      button.disabled = true;
      const { error } = await sb
        .from("catalog_products")
        .update({ active: !product.active })
        .eq("sku", product.sku);

      if (error) {
        feedback.textContent = "No se pudo actualizar el estado: " + error.message;
      } else {
        feedback.textContent = product.active
          ? "El registro quedó oculto en la tienda."
          : "El registro ya está publicado en la tienda.";
      }
      await load();
      return;
    }

    if (button.dataset.delete && confirm("¿Eliminar definitivamente este producto del catálogo?")) {
      button.disabled = true;
      const { error } = await sb
        .from("catalog_products")
        .delete()
        .eq("sku", product.sku);

      if (error) {
        feedback.textContent = "No se pudo eliminar: " + error.message;
      } else {
        await sb.from("checkout_products").update({ active: false }).eq("sku", product.sku);
        feedback.textContent = "Registro eliminado del catálogo.";
        await load();
        if (editing?.sku === product.sku) reset();
      }
    }
  });

  $("#catalog-photos").addEventListener("change", event => {
    const files = [...(event.target.files || [])];
    const invalidFile = files.find(file =>
      !["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
      file.size > 6 * 1024 * 1024
    );

    if (invalidFile) {
      status.textContent = "Cada foto debe ser JPG, PNG o WebP y pesar máximo 6 MB.";
      event.target.value = "";
    }
  });

  form.addEventListener("submit", async event => {
    event.preventDefault();

    const button = $("#catalog-save");
    button.disabled = true;
    status.textContent = "Guardando producto y fotos…";
    feedback.textContent = "";

    try {
      const title = $("#catalog-title").value.trim();
      const slug = $("#catalog-slug").value.trim().toLowerCase();
      const sku = editing?.sku || slug;

      if (!/^[a-z0-9][a-z0-9-]{1,99}$/.test(slug)) {
        throw new Error("Usa una URL corta con letras minúsculas, números y guiones.");
      }

      const bookable = $("#catalog-bookable").checked;
      const price = Math.round(Number($("#catalog-price").value || 0) * 100);
      const kind = $("#catalog-kind").value;
      const min = Number($("#catalog-min").value || 1);
      const max = Number($("#catalog-max").value || 1);

      if (bookable && max < min) {
        throw new Error("La cantidad máxima debe ser igual o mayor que la mínima.");
      }

      const files = [...($("#catalog-photos").files || [])];
      for (let index = 0; index < files.length; index++) {
        const file = files[index];
        const extension = file.name.split(".").pop().toLowerCase();
        const path = sku + "/" + Date.now() + "-" + index + "." + extension;
        const { error } = await sb.storage
          .from("catalog-products")
          .upload(path, file, { upsert: false, contentType: file.type });

        if (error) throw error;

        photos.push(sb.storage.from("catalog-products").getPublicUrl(path).data.publicUrl);
      }

      const payload = {
        sku,
        slug,
        title,
        category: $("#catalog-category").value,
        tag: $("#catalog-badge").value,
        short_description: $("#catalog-short").value.trim(),
        description: $("#catalog-description").value.trim(),
        included_items: lines($("#catalog-includes").value),
        conditions: lines($("#catalog-conditions").value),
        availability_note: $("#catalog-availability").value.trim(),
        images: photos,
        image_alt: title,
        active: $("#catalog-active").checked,
        price_label: $("#catalog-price-label").value.trim(),
        sort_order: Number($("#catalog-sort").value) || 100,
        updated_at: new Date().toISOString()
      };

      const { error } = await sb
        .from("catalog_products")
        .upsert(payload, { onConflict: "sku" });
      if (error) throw error;

      if (bookable) {
        const checkout = {
          sku,
          name: title,
          category: payload.category,
          product_kind: kind,
          unit_amount: price,
          min_quantity: min,
          max_quantity: max,
          pricing_mode: "unit",
          included_quantity: null,
          additional_unit_amount: null,
          sale_ends_on: null,
          sort_order: payload.sort_order,
          active: payload.active
        };

        const { error: checkoutError } = await sb
          .from("checkout_products")
          .upsert(checkout, { onConflict: "sku" });
        if (checkoutError) throw checkoutError;
      } else {
        const { error: checkoutError } = await sb
          .from("checkout_products")
          .update({ active: false })
          .eq("sku", sku);
        if (checkoutError) throw checkoutError;
      }

      await load();
      reset();
      feedback.textContent = "Cambios guardados correctamente. El inventario está actualizado.";
    } catch (error) {
      status.textContent = "No se pudo guardar: " + error.message;
    } finally {
      button.disabled = false;
    }
  });

  $("#catalog-cancel").addEventListener("click", () => {
    reset();
    feedback.textContent = "Volviste al inventario.";
  });

  const { data: { session } } = await sb.auth.getSession();
  if (session) {
    const { data: isAdmin } = await sb.rpc("is_agenda_admin");
    if (isAdmin) {
      tile.hidden = false;
      await load();
    }
  }

  sb.auth.onAuthStateChange(async (_event, session) => {
    if (!session) {
      tile.hidden = true;
      products = [];
      list.replaceChildren();
      summary.textContent = "";
      feedback.textContent = "";
      reset();
      return;
    }

    const { data: isAdmin } = await sb.rpc("is_agenda_admin");
    tile.hidden = !isAdmin;
    if (isAdmin) {
      await load();
    } else {
      products = [];
      list.replaceChildren();
      reset();
    }
  });
}
