/**
 * Inline SVG series. No dependency, no client JavaScript -- it renders on the
 * server like everything else.
 *
 * Four summary tiles cannot tell you whether yesterday was good; a shape can.
 */
export function Bars({
  points, height = 132, colour = "var(--gold-deep)", format,
}: {
  points: { day: string; count: number }[];
  height?: number;
  colour?: string;
  format?: (n: number) => string;
}) {
  if (!points.length) return <p className="empty">No data yet.</p>;

  const max = Math.max(1, ...points.map((p) => p.count));
  const w = 100 / points.length;
  const fmt = format ?? ((n: number) => String(n));

  return (
    <>
      {/* preserveAspectRatio none: the series should fill whatever width the
          card has, and a bar chart has no aspect ratio worth preserving. */}
      <svg className="chart" viewBox="0 0 100 40" preserveAspectRatio="none"
           style={{ height }} role="img" aria-label={`${points.length} day series`}>
        {points.map((p, i) => {
          const h = (p.count / max) * 36;
          return (
            <rect key={p.day} className="bar" fill={colour}
                  x={i * w + w * 0.15} y={38 - h}
                  width={w * 0.7} height={Math.max(h, p.count > 0 ? 0.6 : 0)}>
              <title>{`${p.day}: ${fmt(p.count)}`}</title>
            </rect>
          );
        })}
        <line className="axis" x1="0" y1="38.5" x2="100" y2="38.5" />
      </svg>
      <div className="row" style={{ justifyContent: "space-between", fontSize: 11, color: "var(--faint)" }}>
        <span>{points[0].day}</span>
        <span>peak {fmt(max)}</span>
        <span>{points[points.length - 1].day}</span>
      </div>
    </>
  );
}
