export const metadata = { title: "PREMORTEM API", description: "Test your agent against the world that breaks it." };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body style={{ fontFamily: "system-ui, sans-serif", margin: 0, padding: "32px 16px", background: "#0f1619", color: "#e5edef" }}>
        {children}
      </body>
    </html>
  );
}
