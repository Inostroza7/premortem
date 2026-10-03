export default function Home() {
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", lineHeight: 1.6 }}>
      <h1 style={{ marginBottom: 4 }}>PREMORTEM</h1>
      <p style={{ color: "#96a7ad", marginTop: 0 }}>Test your agent against the world that breaks it.</p>
      <p>Esta aplicación expone la API en <code>/api</code>. Estado del servicio: <a style={{ color: "#3ec4ce" }} href="/api/health">/api/health</a>.</p>
      <p>Documentación para el equipo de front: <code>docs/API.md</code> en el repositorio.</p>
    </main>
  );
}
