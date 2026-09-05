import { callAdmin } from "@/lib/api";

type Entry = { id: number; admin: string; action: string; subject: string; note: string; at: string };

export default async function AuditPage() {
  const res = await callAdmin<{ entries: Entry[] }>("/audit");
  if (!res.ok) return <p className="err">{res.message}</p>;

  return (
    <>
      <h1>Audit trail</h1>
      <p className="muted">
        Every action that changed something, with who did it and when. This is what
        answers “who granted this player a million gold, and why” three months later —
        a question that always eventually gets asked.
      </p>
      <div className="card" style={{ marginTop: 16 }}>
        <table>
          <thead>
            <tr><th>When</th><th>Admin</th><th>Action</th><th>Subject</th><th>Note</th></tr>
          </thead>
          <tbody>
            {res.data.entries.map((e) => (
              <tr key={e.id}>
                <td className="muted">{e.at}</td>
                <td>{e.admin}</td>
                <td><span className="pill">{e.action}</span></td>
                <td className="muted" style={{ fontFamily: "ui-monospace, monospace", fontSize: 11 }}>
                  {e.subject}
                </td>
                <td>{e.note}</td>
              </tr>
            ))}
            {res.data.entries.length === 0 ? (
              <tr><td colSpan={5} className="muted">Nothing yet.</td></tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </>
  );
}
