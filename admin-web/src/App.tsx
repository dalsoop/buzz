import {
  type ChangeEvent,
  type ReactNode,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { Trans, useTranslation } from "react-i18next";
import {
  type AuthMode,
  ApiFailure,
  mutate,
  probeAuthMode,
  request,
  requestObjectUrl,
} from "./api";
import type {
  FeedbackDetail,
  FeedbackStatus,
  FeedbackSummary,
  Report,
  ReportDetail as ReportDetailData,
} from "./types";
import { i18n, setLanguage } from "./i18n";
import { useResource } from "./useResource";

function usePath() {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => {
    const update = () => setPath(location.pathname);
    addEventListener("popstate", update);
    return () => removeEventListener("popstate", update);
  }, []);
  const navigate = useCallback((url: string) => {
    history.pushState(null, "", url);
    dispatchEvent(new PopStateEvent("popstate"));
  }, []);
  return { path, navigate };
}

function Link({
  href,
  className,
  activeWhenNested = false,
  children,
}: {
  href: string;
  className?: string;
  activeWhenNested?: boolean;
  children: ReactNode;
}) {
  const { path, navigate } = usePath();
  const active =
    path === href || (activeWhenNested && path.startsWith(`${href}/`));
  return (
    <a
      href={href}
      className={className}
      aria-current={active ? "page" : undefined}
      onClick={(event) => {
        if (!event.metaKey && !event.ctrlKey) {
          event.preventDefault();
          navigate(href);
        }
      }}
    >
      {children}
    </a>
  );
}

function StateView<T>({
  resource,
  children,
}: {
  resource: ReturnType<typeof useResource<T>>;
  children: (data: T) => ReactNode;
}) {
  const { t } = useTranslation();
  if (resource.loading && !resource.data)
    return <div className="state">{t("state.loading")}</div>;
  if (resource.error && !resource.data) {
    const forbidden =
      resource.error instanceof ApiFailure && resource.error.status === 403;
    return (
      <div className="state error" role="alert">
        <h2>{forbidden ? t("state.accessDenied") : t("state.loadFailed")}</h2>
        <p>{resource.error.message}</p>
        <button type="button" onClick={resource.refetch}>
          {t("state.retry")}
        </button>
      </div>
    );
  }
  return resource.data ? children(resource.data) : null;
}

function Reports({ authMode }: { authMode: AuthMode }) {
  const { t } = useTranslation();
  const resource = useResource(
    () => request<Report[]>("/reports?status=open&limit=100", authMode),
    "reports",
  );
  return (
    <Page
      eyebrow={t("page.moderation")}
      title={t("reports.title")}
      description={t("reports.description")}
    >
      <StateView resource={resource}>
        {(reports) =>
          reports.length ? (
            <div className="cards">
              {reports.map((report) => (
                <Link
                  key={report.id}
                  href={`/reports/${report.id}`}
                  className="card-link"
                >
                  <article className="record-card">
                    <span className="record-icon report-icon">
                      <ReportIcon />
                    </span>
                    <div className="record-primary">
                      <span className="tag">{report.reportType}</span>
                      <strong>{report.communityHost}</strong>
                      <code>
                        {report.targetKind}: {short(report.target)}
                      </code>
                    </div>
                    <div className="record-date">
                      <span>{t("reports.submitted")}</span>
                      <time>{date(report.createdAt)}</time>
                    </div>
                    <ArrowIcon />
                  </article>
                </Link>
              ))}
            </div>
          ) : (
            <Empty />
          )
        }
      </StateView>
    </Page>
  );
}

function ReportDetail({ id, authMode }: { id: string; authMode: AuthMode }) {
  const { t } = useTranslation();
  const resource = useResource(
    () => request<ReportDetailData>(`/reports/${id}`, authMode),
    id,
  );
  return (
    <Page
      eyebrow={t("page.moderation")}
      title={t("reports.detailTitle")}
      description={t("reports.detailDescription")}
      back="/reports"
    >
      <StateView resource={resource}>
        {(report) => (
          <article className="detail">
            <div className="detail-heading">
              <span className="record-icon report-icon">
                <ReportIcon />
              </span>
              <div>
                <span className="tag">{report.reportType}</span>
                <h2>{report.communityHost}</h2>
              </div>
            </div>
            <dl>
              <dt>{t("reports.status")}</dt>
              <dd>
                <span className="status">{report.status}</span>
              </dd>
              <dt>{t("reports.reporter")}</dt>
              <dd>
                <code>{report.reporterPubkey}</code>
              </dd>
              <dt>{t("reports.target")}</dt>
              <dd>
                <code>{report.target}</code>
              </dd>
              {report.targetKind === "event" ? (
                <>
                  <dt>{t("reports.message")}</dt>
                  <dd>
                    {report.message ? (
                      <div className="reported-message">
                        {report.message.deletedAt ? (
                          <span className="status">{t("reports.deleted")}</span>
                        ) : null}
                        <p>{report.message.content}</p>
                        <div className="reported-message-meta">
                          <span>{t("reports.author")}</span>
                          <code>{report.message.authorPubkey}</code>
                          <span>{t("reports.created")}</span>
                          <time>{date(report.message.createdAt)}</time>
                        </div>
                      </div>
                    ) : (
                      <p className="message-unavailable">
                        {t("reports.messageUnavailable")}
                      </p>
                    )}
                  </dd>
                </>
              ) : null}
              <dt>{t("reports.note")}</dt>
              <dd className="sensitive">
                {report.note ?? t("reports.noNote")}
              </dd>
            </dl>
          </article>
        )}
      </StateView>
    </Page>
  );
}

function FeedbackList({ authMode }: { authMode: AuthMode }) {
  const { t } = useTranslation();
  const resource = useResource(
    () => request<FeedbackSummary[]>("/feedback", authMode),
    "feedback",
  );
  const [query, setQuery] = useState("");
  const [community, setCommunity] = useState("all");
  const [timeRange, setTimeRange] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  // Successful PATCH responses override the server-loaded status so the row
  // reflects the new value without a full refetch. Keyed by feedback id.
  const [overrides, setOverrides] = useState<Record<string, FeedbackStatus>>(
    {},
  );

  // Mutations require a named principal; disabled mode's server rejects them
  // (probe reports canAct: false), so the write control is hidden there rather
  // than offering an action that can only fail.
  const canWrite = authMode === "nip98";

  const applyStatus = useCallback((id: string, status: FeedbackStatus) => {
    setOverrides((current) => ({ ...current, [id]: status }));
  }, []);

  return (
    <Page
      eyebrow={t("page.product")}
      title={t("feedback.title")}
      description={t("feedback.description")}
    >
      <StateView resource={resource}>
        {(items) => {
          if (!items.length) return <Empty />;
          return (
            <FeedbackResults
              items={items}
              query={query}
              community={community}
              timeRange={timeRange}
              statusFilter={statusFilter}
              overrides={overrides}
            >
              {({ communities, filtered }) => (
                <>
                  <div className="feedback-filters">
                    <label className="search-field">
                      <span>{t("feedback.search")}</span>
                      <div>
                        <SearchIcon />
                        <input
                          type="search"
                          placeholder={t("feedback.search")}
                          value={query}
                          onChange={(event) => setQuery(event.target.value)}
                        />
                      </div>
                    </label>
                    <label>
                      <span>{t("feedback.community")}</span>
                      <select
                        value={community}
                        onChange={(event) => setCommunity(event.target.value)}
                      >
                        <option value="all">
                          {t("feedback.allCommunities")}
                        </option>
                        {communities.map((host) => (
                          <option key={host} value={host}>
                            {host}
                          </option>
                        ))}
                      </select>
                    </label>
                    <label>
                      <span>{t("feedback.received")}</span>
                      <select
                        value={timeRange}
                        onChange={(event) => setTimeRange(event.target.value)}
                      >
                        <option value="all">{t("feedback.anyTime")}</option>
                        <option value="day">{t("feedback.lastDay")}</option>
                        <option value="week">{t("feedback.lastWeek")}</option>
                        <option value="month">{t("feedback.lastMonth")}</option>
                      </select>
                    </label>
                    <label>
                      <span>{t("feedback.status")}</span>
                      <select
                        value={statusFilter}
                        onChange={(event) =>
                          setStatusFilter(event.target.value)
                        }
                      >
                        <option value="all">{t("feedback.anyStatus")}</option>
                        <option value="new">{t("feedback.statusNew")}</option>
                        <option value="reviewed">
                          {t("feedback.statusReviewed")}
                        </option>
                        <option value="archived">
                          {t("feedback.statusArchived")}
                        </option>
                      </select>
                    </label>
                  </div>
                  <p className="result-count" aria-live="polite">
                    {t("feedback.resultCount", {
                      shown: filtered.length,
                      total: items.length,
                    })}
                  </p>
                  {filtered.length ? (
                    <div className="cards">
                      {filtered.map((item) => (
                        <article
                          key={item.id}
                          className="record-card feedback-card feedback-record"
                        >
                          <Link
                            href={`/feedback/${item.id}`}
                            className="feedback-main-link"
                          >
                            <span className="record-icon feedback-icon">
                              <CategoryIcon category={item.category} />
                            </span>
                            <div className="record-primary">
                              <CategoryTag category={item.category} />
                              <strong>{item.bodySummary}</strong>
                              <span className="record-provenance">
                                <Provenance host={item.communityHost} />
                                <code>{short(item.submitterPubkey)}</code>
                              </span>
                            </div>
                          </Link>
                          <FeedbackStatusControl
                            id={item.id}
                            status={overrides[item.id] ?? item.status}
                            authMode={authMode}
                            canWrite={canWrite}
                            onApplied={applyStatus}
                          />
                          <div className="record-date">
                            <span>{t("feedback.received")}</span>
                            <time>{date(item.receivedAt)}</time>
                          </div>
                          <Link
                            href={`/feedback/${item.id}`}
                            className="record-open-link"
                          >
                            <span className="visually-hidden">
                              {t("feedback.openFrom", {
                                host: hostLabel(item.communityHost),
                              })}
                            </span>
                            <ArrowIcon />
                          </Link>
                        </article>
                      ))}
                    </div>
                  ) : (
                    <div className="state">{t("feedback.noMatch")}</div>
                  )}
                </>
              )}
            </FeedbackResults>
          );
        }}
      </StateView>
    </Page>
  );
}

const STATUS_LABEL_KEYS: Record<FeedbackStatus, string> = {
  new: "feedback.statusNew",
  reviewed: "feedback.statusReviewed",
  archived: "feedback.statusArchived",
};

const STATUS_OPTIONS: FeedbackStatus[] = ["new", "reviewed", "archived"];

/// The per-row lifecycle control. In writable mode it PATCHes the relay and
/// adopts the status from the PATCH response (never optimistically — a failed
/// write leaves the prior status and surfaces an error). In read-only mode it
/// shows the authoritative status as a static badge, since disabled-mode
/// mutations are rejected server-side.
function FeedbackStatusControl({
  id,
  status,
  authMode,
  canWrite,
  onApplied,
}: {
  id: string;
  status: FeedbackStatus;
  authMode: AuthMode;
  canWrite: boolean;
  onApplied: (id: string, status: FeedbackStatus) => void;
}) {
  const { t } = useTranslation();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);

  if (!canWrite) {
    return (
      <span className="feedback-status">
        <span className={`status status-${status}`}>
          {t(STATUS_LABEL_KEYS[status])}
        </span>
      </span>
    );
  }

  const onChange = async (event: ChangeEvent<HTMLSelectElement>) => {
    const next = event.target.value as FeedbackStatus;
    setPending(true);
    setError(false);
    try {
      const updated = await mutate<{ status: FeedbackStatus }>(
        `/feedback/${encodeURIComponent(id)}`,
        "PATCH",
        { status: next },
        authMode,
      );
      onApplied(id, updated.status);
    } catch {
      setError(true);
    } finally {
      setPending(false);
    }
  };

  return (
    <label className="feedback-status">
      <span className="visually-hidden">{t("feedback.status")}</span>
      <select value={status} onChange={onChange} disabled={pending}>
        {STATUS_OPTIONS.map((option) => (
          <option key={option} value={option}>
            {t(STATUS_LABEL_KEYS[option])}
          </option>
        ))}
      </select>
      {error ? (
        <span className="status-error" role="alert">
          {t("feedback.updateFailed")}
        </span>
      ) : null}
    </label>
  );
}

/// Feedback whose source community was purged carries no host. Render an
/// explicit provenance-unavailable marker rather than an empty slot.
function Provenance({ host }: { host: string | null }) {
  const { t } = useTranslation();
  if (host) return host;
  return (
    <span className="provenance-unavailable">
      {t("feedback.communityUnavailable")}
    </span>
  );
}

function hostLabel(host: string | null): string {
  return host ?? i18n.t("feedback.unavailableCommunity");
}

function FeedbackResults({
  items,
  query,
  community,
  timeRange,
  statusFilter,
  overrides,
  children,
}: {
  items: FeedbackSummary[];
  query: string;
  community: string;
  timeRange: string;
  statusFilter: string;
  overrides: Record<string, FeedbackStatus>;
  children: (results: {
    communities: string[];
    filtered: FeedbackSummary[];
  }) => ReactNode;
}) {
  const results = useMemo(() => {
    const communities = [...new Set(items.map((item) => item.communityHost))]
      .filter((host): host is string => Boolean(host))
      .sort((left, right) => left.localeCompare(right));
    const normalizedQuery = query.trim().toLocaleLowerCase();
    const after = timeRangeStart(timeRange);
    const filtered = items.filter((item) => {
      const status = overrides[item.id] ?? item.status;
      if (community !== "all" && item.communityHost !== community) return false;
      if (statusFilter !== "all" && status !== statusFilter) return false;
      if (after !== undefined) {
        const receivedAt = new Date(item.receivedAt).valueOf();
        if (Number.isNaN(receivedAt) || receivedAt < after) return false;
      }
      if (!normalizedQuery) return true;
      return [
        item.bodySummary,
        item.communityHost ?? "",
        item.category ?? "uncategorized",
        item.submitterPubkey,
      ].some((value) => value.toLocaleLowerCase().includes(normalizedQuery));
    });
    return { communities, filtered };
  }, [items, query, community, timeRange, statusFilter, overrides]);
  return children(results);
}

function FeedbackDetailView({
  id,
  authMode,
}: {
  id: string;
  authMode: AuthMode;
}) {
  const { t } = useTranslation();
  const resource = useResource(
    () => request<FeedbackDetail>(`/feedback/${id}`, authMode),
    id,
  );
  return (
    <Page
      eyebrow={t("page.product")}
      title={t("feedback.detailTitle")}
      description={t("feedback.detailDescription")}
      back="/feedback"
      backLabel={t("page.backToFeedback")}
    >
      <StateView resource={resource}>
        {(feedback) => {
          // Without an authoritative host we cannot validate attachment URLs or
          // derive their fetch paths safely, so we render none and mark the
          // provenance unavailable rather than guessing an origin.
          const attachments = feedback.communityHost
            ? feedbackAttachments(
                feedback.id,
                feedback.tags,
                feedback.communityHost,
              )
            : [];
          const body = stripAttachmentMarkdown(feedback.body, attachments);
          return (
            <article className="detail">
              <div className="detail-heading">
                <span className="record-icon feedback-icon">
                  <CategoryIcon category={feedback.category} />
                </span>
                <div>
                  <CategoryTag category={feedback.category} />
                  <h2>
                    <Provenance host={feedback.communityHost} />
                  </h2>
                </div>
              </div>
              <dl>
                <dt>{t("feedback.body")}</dt>
                <dd className="sensitive feedback-body">{body}</dd>
                {attachments.length ? (
                  <>
                    <dt>{t("feedback.attachments")}</dt>
                    <dd className="attachments">
                      {attachments.map((attachment) => (
                        <Attachment
                          key={`${attachment.hash}-${attachment.path}`}
                          attachment={attachment}
                          authMode={authMode}
                        />
                      ))}
                    </dd>
                  </>
                ) : null}
                <dt>{t("feedback.submittedBy")}</dt>
                <dd>
                  <code>{feedback.submitterPubkey}</code>
                </dd>
                <dt>{t("feedback.event")}</dt>
                <dd>
                  <code>{feedback.eventId}</code>
                </dd>
                <dt>{t("feedback.created")}</dt>
                <dd>{date(feedback.eventCreatedAt)}</dd>
                <dt>{t("feedback.received")}</dt>
                <dd>{date(feedback.receivedAt)}</dd>
              </dl>
            </article>
          );
        }}
      </StateView>
    </Page>
  );
}

interface FeedbackAttachment {
  path: string;
  sourceUrl: string;
  mimeType: string;
  hash: string;
  size?: number;
  dimensions?: string;
  filename?: string;
}

function timeRangeStart(range: string) {
  const durations: Record<string, number> = {
    day: 24 * 60 * 60 * 1000,
    week: 7 * 24 * 60 * 60 * 1000,
    month: 30 * 24 * 60 * 60 * 1000,
  };
  const duration = durations[range];
  return duration ? Date.now() - duration : undefined;
}

function feedbackAttachments(
  feedbackId: string,
  tags: string[][],
  communityHost: string,
): FeedbackAttachment[] {
  return tags.flatMap((tag) => {
    if (tag[0] !== "imeta") return [];
    const values = new Map<string, string>();
    for (const entry of tag.slice(1)) {
      const separator = entry.indexOf(" ");
      if (separator > 0) {
        values.set(entry.slice(0, separator), entry.slice(separator + 1));
      }
    }
    const url = values.get("url");
    const mimeType = values.get("m");
    const hash = values.get("x");
    const safeUrl = url && safeAttachmentUrl(url, communityHost);
    if (!safeUrl || !mimeType || !hash) return [];
    const parsedSize = Number(values.get("size"));
    return [
      {
        path: `/feedback/${encodeURIComponent(feedbackId)}/attachments/${hash}`,
        sourceUrl: safeUrl,
        mimeType,
        hash,
        size:
          Number.isFinite(parsedSize) && parsedSize > 0
            ? parsedSize
            : undefined,
        dimensions: values.get("dim"),
        filename: values.get("filename"),
      },
    ];
  });
}

function safeAttachmentUrl(value: string, communityHost: string) {
  try {
    const url = new URL(value, `${location.protocol}//${communityHost}`);
    return ["http:", "https:"].includes(url.protocol) &&
      url.host.toLocaleLowerCase() === communityHost.toLocaleLowerCase() &&
      url.pathname.startsWith("/media/")
      ? url.href
      : undefined;
  } catch {
    return undefined;
  }
}

function stripAttachmentMarkdown(
  body: string,
  attachments?: FeedbackAttachment[],
) {
  const knownUrls = attachments
    ? new Set(attachments.map((attachment) => attachment.sourceUrl))
    : undefined;
  return body
    .replace(/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (match, url) => {
      const isMedia = knownUrls ? knownUrls.has(url) : url.includes("/media/");
      return isMedia ? "" : match;
    })
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function Attachment({
  attachment,
  authMode,
}: {
  attachment: FeedbackAttachment;
  authMode: AuthMode;
}) {
  const { t } = useTranslation();
  const [objectUrl, setObjectUrl] = useState<string>();
  const [objectType, setObjectType] = useState<string>();
  const [failed, setFailed] = useState(false);
  const path = attachment.path;
  const name =
    attachment.filename ?? `attachment-${attachment.hash.slice(0, 8)}`;
  const metadata = [
    attachment.mimeType,
    attachment.dimensions,
    attachment.size ? formatBytes(attachment.size) : undefined,
  ]
    .filter(Boolean)
    .join(" · ");

  useEffect(() => {
    // The API requires an Authorization header, so the bytes are fetched here
    // and handed to the DOM as an object URL revoked on replacement/unmount.
    let url: string | undefined;
    let active = true;
    setObjectUrl(undefined);
    setObjectType(undefined);
    setFailed(false);
    requestObjectUrl(path, authMode)
      .then((created) => {
        if (!active) {
          URL.revokeObjectURL(created.url);
          return;
        }
        url = created.url;
        setObjectUrl(created.url);
        setObjectType(created.type);
      })
      .catch(() => {
        if (active) setFailed(true);
      });
    return () => {
      active = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [path, authMode]);

  const detail = failed ? t("feedback.attachmentFailed") : metadata;

  // Inline rendering is gated on the server-VERIFIED blob type, never the
  // reporter-supplied `attachment.mimeType`: the relay only labels sniffed
  // passive raster images as `image/*` and forces everything else to
  // `application/octet-stream`, so a hostile payload can never render inline.
  if (objectUrl && objectType?.startsWith("image/")) {
    return (
      <figure className="image-attachment">
        <a href={objectUrl} target="_blank" rel="noreferrer">
          <img src={objectUrl} alt={name} />
        </a>
        <figcaption>
          <span>{name}</span>
          <small>{detail}</small>
        </figcaption>
      </figure>
    );
  }

  const label = (
    <>
      <FileIcon />
      <span>
        <strong>{name}</strong>
        <small>{detail}</small>
      </span>
    </>
  );

  // Until the bytes are fetched there is nothing a link could point at: the
  // API path itself would open unauthenticated in a new tab.
  if (!objectUrl) return <div className="file-attachment">{label}</div>;

  // Non-image (or not-yet-typed) payloads are download-only. The object URL
  // already wraps `application/octet-stream` bytes, and the `download`
  // attribute with no `target="_blank"` means clicking saves the file rather
  // than navigating to a typed document on the admin origin.
  return (
    <a className="file-attachment" href={objectUrl} download={name}>
      {label}
      <ArrowIcon />
    </a>
  );
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function Page({
  eyebrow,
  title,
  description,
  back,
  backLabel,
  children,
}: {
  eyebrow: string;
  title: string;
  description: string;
  back?: string;
  backLabel?: string;
  children: ReactNode;
}) {
  const { t } = useTranslation();
  return (
    <section>
      <header className="page-title">
        {back ? (
          <Link href={back} className="back-link">
            <ArrowIcon /> {backLabel ?? t("page.backToReports")}
          </Link>
        ) : null}
        <p>{eyebrow}</p>
        <h1>{title}</h1>
        <span>{description}</span>
      </header>
      {children}
    </section>
  );
}

function Empty() {
  const { t } = useTranslation();
  return <div className="state">{t("state.noRecords")}</div>;
}

function short(value: string) {
  return value.length > 20 ? `${value.slice(0, 10)}…${value.slice(-8)}` : value;
}

function date(value: string) {
  const parsed = new Date(value);
  return Number.isNaN(parsed.valueOf())
    ? i18n.t("state.unknownDate")
    : parsed.toLocaleString(i18n.resolvedLanguage);
}

function BuzzMark() {
  return (
    <svg viewBox="0 0 466 309" aria-hidden="true">
      <path d="M91.7 62.8a91.7 91.7 0 0 0 0 183.4H128V62.8H91.7Zm282.6 0H338v183.4h36.3a91.7 91.7 0 1 0 0-183.4Z" />
      <path
        fillRule="evenodd"
        d="M162 0h142a34 34 0 0 1 34 34v241a34 34 0 0 1-34 34H162a34 34 0 0 1-34-34V34a34 34 0 0 1 34-34Zm31.3 57.4a27 27 0 1 0 0 54 27 27 0 0 0 0-54Zm82.7 0a27 27 0 1 0 0 54 27 27 0 0 0 0-54Zm-109.7 99.8h136.9v38.3H166.3v-38.3Zm.6 77.9h136.2v37.6H166.9v-37.6Z"
        clipRule="evenodd"
      />
    </svg>
  );
}

function ReportIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 3 4.5 6v5.2c0 4.7 3.2 8.8 7.5 9.8 4.3-1 7.5-5.1 7.5-9.8V6L12 3Z" />
      <path d="M12 7.5v5M12 16.5h.01" />
    </svg>
  );
}

function FeedbackIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 5.5h14v10H9l-4 3v-13Z" />
      <path d="M8.5 9h7M8.5 12h4.5" />
    </svg>
  );
}

function CategoryTag({ category }: { category?: string }) {
  const { t } = useTranslation();
  const labels: Record<string, string> = {
    bug: t("feedback.categoryBug"),
    praise: t("feedback.categoryPraise"),
    "needs-work": t("feedback.categoryNeedsWork"),
  };
  return (
    <span className="tag">
      <CategoryIcon category={category} />
      {category ? (labels[category] ?? category) : t("feedback.uncategorized")}
    </span>
  );
}

function CategoryIcon({ category }: { category?: string }) {
  if (category === "bug") return <BugIcon />;
  if (category === "praise") return <ThumbsUpIcon />;
  if (category === "needs-work") return <WrenchIcon />;
  return <FeedbackIcon />;
}

function BugIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 20v-9" />
      <path d="M14 7a4 4 0 0 1 4 4v3a6 6 0 0 1-12 0v-3a4 4 0 0 1 4-4z" />
      <path d="M14.12 3.88 16 2M21 21a4 4 0 0 0-3.81-4M21 5a4 4 0 0 1-3.55 3.97M22 13h-4M3 21a4 4 0 0 1 3.81-4M3 5a4 4 0 0 0 3.55 3.97M6 13H2M8 2l1.88 1.88M9 7.13V6a3 3 0 1 1 6 0v1.13" />
    </svg>
  );
}

function ThumbsUpIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M15 5.88 14 10h5.83a2 2 0 0 1 1.92 2.56l-2.33 8A2 2 0 0 1 17.5 22H4a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2h2.76a2 2 0 0 0 1.79-1.11L12 2a3.13 3.13 0 0 1 3 3.88Z" />
      <path d="M7 10v12" />
    </svg>
  );
}

function WrenchIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z" />
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4 4" />
    </svg>
  );
}

function FileIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M6 3h8l4 4v14H6V3Z" />
      <path d="M14 3v5h4M9 13h6M9 17h4" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg className="arrow-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="m9 18 6-6-6-6" />
    </svg>
  );
}

/// Shown in nip98 mode when no NIP-07 extension is available. Instructs the
/// operator to install nos2x or Alby before continuing.
function Nip07Screen() {
  const { t } = useTranslation();
  return (
    <div className="app">
      <div className="state auth-prompt">
        <h2>{t("nip07.title")}</h2>
        <p>
          <Trans
            i18nKey="nip07.body"
            components={{
              nos2x: (
                // biome-ignore lint/a11y/useAnchorContent: Trans supplies the link text.
                <a
                  href="https://github.com/fiatjaf/nos2x"
                  target="_blank"
                  rel="noreferrer"
                />
              ),
              alby: (
                // biome-ignore lint/a11y/useAnchorContent: Trans supplies the link text.
                <a
                  href="https://getalby.com"
                  target="_blank"
                  rel="noreferrer"
                />
              ),
            }}
          />
        </p>
        <button type="button" onClick={() => location.reload()}>
          {t("nip07.reload")}
        </button>
      </div>
    </div>
  );
}

function LanguageToggle() {
  const { t, i18n: instance } = useTranslation();
  const next = instance.resolvedLanguage === "ko" ? "en" : "ko";
  const nextLabel = t(`language.${next}`);
  return (
    <button
      type="button"
      className="nav-link language-toggle"
      onClick={() => setLanguage(next)}
      aria-label={t("language.switchTo", { language: nextLabel })}
    >
      {nextLabel}
    </button>
  );
}

export function App() {
  const { t } = useTranslation();
  const { path } = usePath();

  // Probe the relay once to discover the auth mode. `null` means the probe is
  // still in flight. Once resolved, the mode is stable for the session.
  const [authMode, setAuthMode] = useState<AuthMode | null>(null);
  useEffect(() => {
    let active = true;
    probeAuthMode().then((mode) => {
      if (active) setAuthMode(mode);
    });
    return () => {
      active = false;
    };
  }, []);

  const report = path.match(/^\/reports\/([^/]+)$/);
  const feedback = path.match(/^\/feedback\/([^/]+)$/);

  // Probe still in flight — render nothing to avoid a visible flash.
  if (authMode === null) return null;

  // NIP-98 mode: require a NIP-07 extension.
  if (authMode === "nip98" && !(window as Window & { nostr?: unknown }).nostr)
    return <Nip07Screen />;

  const content = report ? (
    <ReportDetail id={report[1]} authMode={authMode} />
  ) : feedback ? (
    <FeedbackDetailView id={feedback[1]} authMode={authMode} />
  ) : path === "/feedback" ? (
    <FeedbackList authMode={authMode} />
  ) : (
    <Reports authMode={authMode} />
  );
  return (
    <div className="app">
      <header className="app-header">
        <Link href="/reports" className="brand">
          <span className="brand-mark">
            <BuzzMark />
          </span>
          <span>
            Buzz <b>{t("nav.admin")}</b>
          </span>
        </Link>
        <nav>
          <Link href="/reports" className="nav-link" activeWhenNested>
            <ReportIcon /> {t("nav.reports")}
          </Link>
          <Link href="/feedback" className="nav-link" activeWhenNested>
            <FeedbackIcon /> {t("nav.feedback")}
          </Link>
          <LanguageToggle />
        </nav>
      </header>
      <main>{content}</main>
    </div>
  );
}
