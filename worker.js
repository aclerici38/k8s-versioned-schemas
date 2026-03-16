import redirectData from "./_redirects.json";

const { latest, groups } = redirectData;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.toLowerCase().split("/").filter(Boolean);

    if (parts.length >= 2) {
      const [first, ...rest] = parts;

      // /app/latest/* -> /app/{version}/*
      if (first in latest && rest[0] === "latest") {
        const newPath = `/${first}/${latest[first]}/${rest.slice(1).join("/")}`;
        return Response.redirect(new URL(newPath, url.origin).toString(), 302);
      }

      // /group/kind_version.json -> /app/{version}/kind_version.json
      if (first in groups) {
        const app = groups[first];
        const newPath = `/${app}/${latest[app]}/${rest.join("/")}`;
        return Response.redirect(new URL(newPath, url.origin).toString(), 302);
      }
    }

    // Inject values schema into helmrelease via '?values=app/version'
    // e.g. /flux/2.8.3/helmrelease_v2.json?values=cilium/0.19.1
    const values = url.searchParams.get("values");
    if (values) {
      const [app, ver] = values.split("/");
      const resolved = ver === "latest" ? latest[app] : ver;
      const asset = (path) =>
        env.ASSETS.fetch(new Request(new URL(path, url.origin)));

      const [baseRes, valuesRes] = await Promise.all([
        asset(url.pathname),
        asset(`/${app}/${resolved}/values.schema.json`),
      ]);
      if (!baseRes.ok || !valuesRes.ok) {
        return new Response("Schema not found", { status: 404 });
      }

      const schema = await baseRes.json();
      const valuesRaw = await valuesRes.text();
      const prefix = "#/properties/spec/properties/values";
      schema.properties.spec.properties.values = JSON.parse(
        valuesRaw.replaceAll('"#/', `"${prefix}/`),
      );
      return Response.json(schema);
    }

    return env.ASSETS.fetch(request);
  },
};
