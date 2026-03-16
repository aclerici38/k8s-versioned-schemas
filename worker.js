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
        const dest = new URL(`/${first}/${latest[first]}/${rest.slice(1).join("/")}`, url.origin);
        dest.search = url.search;
        return Response.redirect(dest.toString(), 302);
      }

      // /group/kind_version.json -> /app/{version}/kind_version.json
      if (first in groups) {
        const app = groups[first];
        const dest = new URL(`/${app}/${latest[app]}/${rest.join("/")}`, url.origin);
        dest.search = url.search;
        return Response.redirect(dest.toString(), 302);
      }
    }

    // Inject values schema ref into helmrelease via '?values=app/version'
    // e.g. /flux/2.8.3/helmrelease_v2.json?values=cilium/0.19.1
    const values = url.searchParams.get("values");
    if (values) {
      const [app, ver] = values.split("/");
      const resolved = ver === "latest" ? latest[app] : ver;

      const baseRes = await env.ASSETS.fetch(
        new Request(new URL(url.pathname, url.origin)),
      );
      if (!baseRes.ok) {
        return new Response("Schema not found", { status: 404 });
      }

      const schema = await baseRes.json();
      schema.properties.spec.properties.values = {
        $ref: `${url.origin}/${app}/${resolved}/values.schema.json`,
      };
      return Response.json(schema);
    }

    return env.ASSETS.fetch(request);
  },
};
