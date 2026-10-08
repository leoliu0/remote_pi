/// Public Remote Pi website: download page and docs.
const String kSiteBaseUrl = 'https://remote-pi.jacobmoura.work';

/// This fork's own web client (`/web`), served over HTTPS from the relay VPS.
/// "Sign in on web" only delivers the owner key to a browser showing a
/// `remotepi://web-login` code for this host, so it must only ever point at a
/// site this deployment controls, never at [kSiteBaseUrl].
const String kWebClientBaseUrl = 'https://178-157-59-181.sslip.io';
