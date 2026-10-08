/// Public Remote Pi website: download page and docs.
const String kSiteBaseUrl = 'https://remote-pi.jacobmoura.work';

/// This fork's own web client (`/web`), served over HTTPS from the relay VPS.
/// The "Sign in on web" link carries the owner key, so it must only ever point
/// at a site this deployment controls, never at [kSiteBaseUrl].
const String kWebClientBaseUrl = 'https://178-157-59-181.sslip.io';
