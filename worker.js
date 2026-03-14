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

    return env.ASSETS.fetch(request);
  },
};
