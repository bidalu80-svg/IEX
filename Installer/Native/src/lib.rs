//! Narrow, memory-only ABI. No tracing subscriber, filesystem pairing records,
//! Apple-account, signing, install, DDI, JIT, or generic lockdown command API.
use std::{ffi::{CStr, CString, c_char, c_void}, sync::{Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};
use idevice::{lockdown::LockdownClient, remote_pairing::{PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native}, rsd::RsdHandshake, tcp::{adapter::Adapter, handle::AdapterHandle}};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{net::{TcpListener, TcpStream}, runtime::Runtime};

type Result<T> = std::result::Result<T, &'static str>;
type Event = Option<extern "C" fn(*mut c_void, i32, *const c_char)>;
#[derive(Clone, Serialize, Deserialize)]
struct Identity { version: u8, pairing: Vec<u8>, host_irk: [u8;16], peer_udid: Option<String> }
impl Identity {
    fn generate() -> Self {
        let mut pairing = RpPairingFile::generate("Ze connection experiment");
        pairing.identifier = uuid::Uuid::new_v4().to_string();
        let host = PairableHostInfo::generate("Ze connection experiment", "Mac17,7");
        Self { version: 1, pairing: pairing.to_bytes(), host_irk: host.alt_irk, peer_udid: None }
    }
    fn parse(&self) -> Result<RpPairingFile> {
        if self.version != 1 || self.pairing.len() > 65536 { return Err("identityInvalid"); }
        let file = RpPairingFile::from_bytes(&self.pairing).map_err(|_| "identityInvalid")?;
        if uuid::Uuid::parse_str(&file.identifier).is_err() || file.e_private_key.verifying_key() != file.e_public_key {
            return Err("identityInvalid");
        }
        if self.peer_udid.is_some() != file.peer_public_key.is_some() || self.peer_udid.is_some() != file.peer_identifier.is_some() || self.peer_udid.is_some() != file.alt_irk.is_some() || file.alt_irk.as_ref().is_some_and(|x| x.len() != 16) {
            return Err("identityInvalid");
        }
        Ok(file)
    }
    fn host(&self, file: &RpPairingFile) -> PairableHostInfo {
        PairableHostInfo { name: "Ze connection experiment".into(), model: "Mac17,7".into(),
            identifier: file.identifier.clone(), alt_irk: self.host_irk, allows_pinless_pairing: false, ..Default::default() }
    }
    fn response(&self) -> Result<Value> {
        let file = self.parse()?; let host = self.host(&file);
        Ok(json!({"secret": self, "identifier": file.identifier,
            "txt": host.mdns_txt_records(&file.identifier).into_iter().collect::<std::collections::BTreeMap<_,_>>(),
            "paired": self.peer_udid.is_some()}))
    }
}
#[derive(Default)]
struct State { identity: Option<Identity>, listener: Option<TcpListener>, adapter: Option<AdapterHandle>, lockdown: Option<LockdownClient> }
pub struct ZeSession { cancel: AtomicBool, runtime: Runtime, state: Mutex<State> }
fn emit(event: Event, context: *mut c_void, code: i32, pin: Option<&str>) {
    let pin = pin.and_then(|x| CString::new(x).ok());
    if let Some(callback) = event { callback(context, code, pin.as_ref().map_or(std::ptr::null(), |x| x.as_ptr())); }
}
async fn timed<T>(seconds: u64, code: &'static str, future: impl Future<Output=std::result::Result<T, idevice::IdeviceError>>) -> Result<T> {
    tokio::time::timeout(Duration::from_secs(seconds), future).await.map_err(|_| "timeout")?.map_err(|error| match error {
        idevice::IdeviceError::RemotePairing(idevice::remote_pairing::errors::RemotePairingError::SrpAuthFailed) => "wrongPIN",
        _ => code
    })
}
// LocalDevVPN Wi-Fi route. Cover the entire dynamic range, except known
// unrelated lockdown 62078. Prioritize reference-observed 55021 and both bounds.
// <=32 in-flight TCP/protocol probes; 200ms TCP, 1s protocol, 30s total discovery.
fn discovery_ports() -> Vec<u16> {
    let mut ports = vec![49152, 55021, 65535];
    ports.extend((49152..=65535).filter(|p| ![49152,55021,65535,62078].contains(p)));
    ports
}
fn classify_tcp_error(error: &std::io::Error) -> &'static str {
    match error.kind() {
        std::io::ErrorKind::ConnectionRefused => "connectionRefused",
        std::io::ErrorKind::TimedOut => "connectionTimeout",
        _ => "disconnected",
    }
}
fn classify_protocol_error(error: idevice::IdeviceError) -> &'static str {
    match error {
        idevice::IdeviceError::Socket(error) => classify_tcp_error(&error),
        idevice::IdeviceError::Timeout => "connectionTimeout",
        _ => "wrongService",
    }
}
fn classify_verify_error(error: idevice::IdeviceError) -> &'static str {
    match error {
        idevice::IdeviceError::Socket(error) => classify_tcp_error(&error),
        idevice::IdeviceError::Timeout => "connectionTimeout",
        idevice::IdeviceError::RemotePairing(idevice::remote_pairing::errors::RemotePairingError::PairVerifyFailed) => "identityRejected",
        _ => "wrongService",
    }
}
#[derive(Default)]
struct DiscoveryFailures { refused: usize, timeout: usize, wrong_service: usize, other: usize }
impl DiscoveryFailures {
    fn observe(&mut self, code: &str) {
        match code { "connectionRefused" => self.refused += 1, "connectionTimeout" => self.timeout += 1,
            "wrongService" => self.wrong_service += 1, _ => self.other += 1 }
    }
    // Most specific acquired evidence wins. All-refused is never wrongService;
    // an exhausted deadline is a timeout, not a claim that all ports were checked.
    fn conclusion(&self) -> &'static str {
        if self.wrong_service > 0 { "wrongService" } else if self.timeout > 0 { "connectionTimeout" }
        else if self.other > 0 { "disconnected" } else { "connectionRefused" }
    }
}
type PairingClient = RemotePairingClient<RpPairingSocket<TcpStream>>;
async fn probe_endpoint(port: u16) -> Result<PairingClient> {
    let stream = tokio::time::timeout(Duration::from_millis(200), TcpStream::connect(("10.7.0.1",port))).await
        .map_err(|_| "connectionTimeout")?.map_err(|error| classify_tcp_error(&error))?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "Ze connection experiment");
    tokio::time::timeout(Duration::from_secs(1), rpc.attempt_pair_verify()).await
        .map_err(|_| "connectionTimeout")?.map_err(classify_protocol_error)?;
    Ok(rpc)
}
async fn discover(file: &mut RpPairingFile, event: Event, context: *mut c_void) -> Result<PairingClient> {
    let mut ports = discovery_ports().into_iter();
    let mut probes = tokio::task::JoinSet::new();
    let mut failures = DiscoveryFailures::default();
    for port in ports.by_ref().take(32) { probes.spawn(probe_endpoint(port)); }
    while let Some(result) = probes.join_next().await {
        match result {
            Ok(Ok(mut rpc)) => {
                emit(event, context, 2, None);
                // Never fall back to pair-setup. Identity rejection terminates the
                // trial and retains the stored identity; it is not a scan failure.
                tokio::time::timeout(Duration::from_secs(5), rpc.validate_pairing(file)).await
                    .map_err(|_| "connectionTimeout")?.map_err(classify_verify_error)?;
                emit(event, context, 3, None);
                return Ok(rpc); // dropping JoinSet cancels all outstanding probes
            }
            Ok(Err(code)) => failures.observe(code),
            Err(_) => failures.observe("disconnected"),
        }
        if let Some(port) = ports.next() { probes.spawn(probe_endpoint(port)); }
    }
    Err(failures.conclusion())
}
async fn connect(state: &mut State, event: Event, context: *mut c_void) -> Result<Value> {
    let identity = state.identity.as_ref().ok_or("identityUnavailable")?;
    let mut file = identity.parse()?;
    if identity.peer_udid.is_none() { return Err("identityUnavailable"); }
    let mut rpc = tokio::time::timeout(Duration::from_secs(30), discover(&mut file,event,context)).await
        .map_err(|_| "connectionTimeout")??;
    let port = timed(5, "tlsFailed", rpc.create_tcp_listener()).await?;
    if port == 0 { return Err("tunnelParameters"); }
    let stream = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(("10.7.0.1", port))).await
        .map_err(|_| "timeout")?.map_err(|_| "disconnected")?;
    let tunnel = timed(10, "tlsFailed", connect_tls_psk_tunnel_native(stream, rpc.encryption_key())).await?;
    let client = tunnel.info.client_address.parse().map_err(|_| "tunnelParameters")?;
    let server = tunnel.info.server_address.parse().map_err(|_| "tunnelParameters")?;
    let mtu = tunnel.info.mtu as usize; let rsd_port = tunnel.info.server_rsd_port;
    if !(1280..=65535).contains(&mtu) || rsd_port == 0 || client == server { return Err("tunnelParameters"); }
    emit(event, context, 4, None);
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client, server);
    adapter.set_mss(mtu.min(8192) - 60);
    let mut adapter = adapter.to_async_handle();
    let stream = tokio::time::timeout(Duration::from_secs(5), adapter.connect(rsd_port)).await
        .map_err(|_| "timeout")?.map_err(|_| "rsdFailed")?;
    let host_uuid = uuid::Uuid::parse_str(&file.identifier).map_err(|_| "identityInvalid")?;
    let mut rsd = timed(5, "rsdFailed", RsdHandshake::new_with_uuid(stream, host_uuid)).await?;
    if !rsd.services.contains_key("com.apple.mobile.lockdown.remote.trusted") { return Err("serviceMissing"); }
    emit(event, context, 5, None);
    let lockdown = timed(5, "serviceMissing", rsd.connect::<LockdownClient>(&mut adapter)).await?;
    state.adapter = Some(adapter); state.lockdown = Some(lockdown);
    Ok(json!({}))
}
async fn operation(state: &mut State, op: &str, input: Value, event: Event, context: *mut c_void) -> Result<Value> {
    match op {
        "prepare" => {
            let identity = if input["saved"].is_null() {
                if input["allowNewIdentity"].as_bool() != Some(true) { return Err("identityCreationRequired"); }
                Identity::generate()
            } else {
                serde_json::from_value(input["saved"].clone()).map_err(|_| "identityInvalid")?
            };
            let response = identity.response()?; state.identity = Some(identity); Ok(response)
        }
        "listen" => {
            if state.listener.is_some() || state.identity.is_none() { return Err("listenerFailed"); }
            let listener = TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED,0)).await.map_err(|_| "listenerFailed")?;
            let port = listener.local_addr().map_err(|_| "listenerFailed")?.port();
            state.listener = Some(listener); Ok(json!({"port":port}))
        }
        "pair" => {
            let listener = state.listener.take().ok_or("listenerFailed")?;
            let identity = state.identity.as_mut().ok_or("identityUnavailable")?;
            let mut file = identity.parse()?;
            if identity.peer_udid.is_some() { return Err("identityInvalid"); }
            let (stream, _) = listener.accept().await.map_err(|_| "disconnected")?;
            drop(listener); // single peer, no second accept/backlog after pairing starts
            let mut host = PairableHost::new(RpPairingSocket::new_device(stream), identity.host(&file));
            let peer = timed(90, "pairingRejected", host.accept(&mut file, |pin| {
                emit(event, context, 1, Some(&pin)); async {}
            })).await?;
            if peer.remotepairing_udid.is_empty() { return Err("identityInvalid"); }
            identity.pairing = file.to_bytes(); identity.peer_udid = Some(peer.remotepairing_udid);
            identity.response()
        }
        "connect" => connect(state, event, context).await,
        "query" => {
            let id = input["requestID"].as_str().ok_or("staleResponse")?;
            uuid::Uuid::parse_str(id).map_err(|_| "staleResponse")?;
            let lockdown = state.lockdown.as_mut().ok_or("serviceMissing")?;
            // Only these three hardcoded read-only keys. UDID never leaves this
            // function: compare to the authenticated pairing identity in memory.
            let product = timed(5, "queryFailed", lockdown.get_value(Some("ProductVersion"),None)).await?;
            let build = timed(5, "queryFailed", lockdown.get_value(Some("BuildVersion"),None)).await?;
            let udid = timed(5, "queryFailed", lockdown.get_value(Some("UniqueDeviceID"),None)).await?;
            let expected = state.identity.as_ref().and_then(|x| x.peer_udid.as_deref()).ok_or("identityUnavailable")?;
            if udid.as_string() != Some(expected) { return Err("identityMismatch"); }
            let product = product.as_string().filter(|s| !s.is_empty()).ok_or("queryFailed")?;
            let build = build.as_string().filter(|s| !s.is_empty()).ok_or("queryFailed")?;
            Ok(json!({"requestID": id, "productVersion": product, "buildVersion": build, "identityMatches": true}))
        }
        _ => Err("backendUnavailable")
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn ze_connection_new() -> *mut ZeSession {
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => Box::into_raw(Box::new(ZeSession { cancel: AtomicBool::new(false), runtime, state: Mutex::new(State::default()) })),
        Err(_) => std::ptr::null_mut()
    }
}
/// # Safety: live handle, may run concurrently with run; not with free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ze_connection_cancel(session: *const ZeSession) {
    if let Some(session) = unsafe { session.as_ref() } { session.cancel.store(true, Ordering::Release); }
}
/// # Safety: live handle, after worker completion and all cancellation calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ze_connection_free(session: *mut ZeSession) {
    if !session.is_null() { drop(unsafe { Box::from_raw(session) }); }
}
/// # Safety: live serial-use session; valid NUL terminated input/op; callback
/// context lives until return. Callback must not free/re-enter the session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ze_connection_run(session: *mut ZeSession, op: *const c_char, input: *const c_char, event: Event, context: *mut c_void) -> *mut c_char {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value> {
        let session = unsafe { session.as_ref() }.ok_or("backendUnavailable")?;
        if op.is_null() || input.is_null() { return Err("identityInvalid"); }
        if session.cancel.load(Ordering::Acquire) { return Err("cancelled"); }
        let op = unsafe { CStr::from_ptr(op) }.to_str().map_err(|_| "identityInvalid")?;
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        if bytes.len() > 128*1024 { return Err("identityInvalid"); }
        let input: Value = serde_json::from_slice(bytes).map_err(|_| "identityInvalid")?;
        let mut state = session.state.lock().map_err(|_| "backendUnavailable")?;
        session.runtime.block_on(async {
            tokio::select! {
                result = operation(&mut state, op, input, event, context) => result,
                _ = async { loop { if session.cancel.load(Ordering::Acquire) { break; } tokio::time::sleep(Duration::from_millis(10)).await; } } => Err("cancelled"),
                _ = tokio::time::sleep(Duration::from_secs(120)) => Err("timeout")
            }
        })
    }));
    let value = match result { Ok(Ok(value)) => json!({"ok":value}), Ok(Err(code)) => json!({"error":code}), Err(_) => json!({"error":"backendUnavailable"}) };
    CString::new(value.to_string()).expect("JSON has no NUL bytes").into_raw()
}
/// # Safety: output allocated by run; free exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ze_connection_string_free(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test] async fn independent_wire_peer_wrong_pin_proof_is_rejected() {
        use base64::Engine;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let b64 = base64::engine::general_purpose::STANDARD;
        let identity = Identity::generate(); let mut file = identity.parse().unwrap();
        let (stream, mut peer) = tokio::io::duplex(8192);
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), identity.host(&file));
        let pin_shown = AtomicBool::new(false);
        async fn send(peer: &mut tokio::io::DuplexStream, message: Value) {
            let data = json!({"message":{"plain":{"_0":message}},"originatedBy":"host","sequenceNumber":0}).to_string();
            peer.write_all(b"RPPairing").await.unwrap(); peer.write_all(&(data.len() as u16).to_be_bytes()).await.unwrap();
            peer.write_all(data.as_bytes()).await.unwrap();
        }
        async fn receive(peer: &mut tokio::io::DuplexStream) -> Value {
            let mut header = [0u8;11]; peer.read_exact(&mut header).await.unwrap();
            assert_eq!(&header[..9], b"RPPairing");
            let length = u16::from_be_bytes([header[9],header[10]]) as usize;
            let mut body = vec![0;length]; peer.read_exact(&mut body).await.unwrap(); serde_json::from_slice(&body).unwrap()
        }
        let fake = async {
            send(&mut peer,json!({"request":{"_0":{"handshake":{"_0":{"hostOptions":{"attemptPairVerify":false}}}}}})).await;
            let _ = receive(&mut peer).await;
            send(&mut peer,json!({"event":{"_0":{"pairingData":{"_0":{"data":b64.encode([6,1,1])}}}}})).await;
            let _ = receive(&mut peer).await; // independent fake peer deliberately does not use host PIN
            let mut m3 = vec![6,1,3,3,1,5,4,64]; m3.extend_from_slice(&[0;64]);
            send(&mut peer,json!({"event":{"_0":{"pairingData":{"_0":{"data":b64.encode(m3)}}}}})).await;
            let response = receive(&mut peer).await;
            let data = response["message"]["plain"]["_0"]["event"]["_0"]["pairingData"]["_0"]["data"].as_str().unwrap();
            assert_eq!(b64.decode(data).unwrap(), [6,1,4,7,1,2]);
        };
        let accept = host.accept(&mut file, |_| { pin_shown.store(true, Ordering::Release); async {} });
        let (result, _) = tokio::time::timeout(Duration::from_secs(5), async { tokio::join!(accept, fake) }).await.unwrap();
        assert!(matches!(result, Err(idevice::IdeviceError::RemotePairing(idevice::remote_pairing::errors::RemotePairingError::SrpAuthFailed))));
        assert!(pin_shown.load(Ordering::Acquire)); assert!(file.alt_irk.is_none());
    }
    #[tokio::test] async fn responder_rejects_disconnected_peer_without_pin() {
        let identity = Identity::generate(); let mut file = identity.parse().unwrap();
        let (stream, peer) = tokio::io::duplex(4096); drop(peer);
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), identity.host(&file));
        let called = std::sync::atomic::AtomicBool::new(false);
        let result = tokio::time::timeout(Duration::from_secs(1), host.accept(&mut file, |_| {
            called.store(true, Ordering::Release); async {}
        })).await.unwrap();
        assert!(result.is_err()); assert!(!called.load(Ordering::Acquire));
    }
    #[tokio::test] async fn tls_psk_rejects_independent_peer_alert() {
        use tokio::io::AsyncWriteExt;
        let (stream, mut peer) = tokio::io::duplex(8192);
        peer.write_all(&[21,3,3,0,2,2,40]).await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), connect_tls_psk_tunnel_native(stream, &[7;32])).await.unwrap();
        assert!(result.is_err());
    }
    #[test] fn independent_ed25519_vector_rejects_tamper_and_wrong_identity() {
        fn bytes(hex: &str) -> Vec<u8> { (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i+2],16).unwrap()).collect() }
        let key = bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
        let signature = bytes("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
        assert!(idevice::remote_pairing::verify_peer_signature(&key, &signature, b"").is_ok());
        assert!(idevice::remote_pairing::verify_peer_signature(&key, &signature, b"tamper").is_err());
        let mut wrong = key.clone(); wrong[0] ^= 1;
        assert!(idevice::remote_pairing::verify_peer_signature(&wrong, &signature, b"").is_err());
        assert!(idevice::remote_pairing::verify_peer_signature(&key, &signature[..63], b"").is_err());
    }
    #[test] fn tls_finished_requires_real_proof_and_valid_header() {
        use idevice::remote_pairing::tls_psk::validate_server_finished;
        let expected = [7;12]; let mut packet = vec![20,0,0,12]; packet.extend_from_slice(&expected);
        assert!(validate_server_finished(&packet, &expected).is_ok());
        packet[15] ^= 1; assert!(validate_server_finished(&packet, &expected).is_err());
        assert!(validate_server_finished(&[], &expected).is_err());
        packet[15] ^= 1; packet[3] = 11; assert!(validate_server_finished(&packet, &expected).is_err());
    }
    #[test] fn cdtunnel_rejects_truncation_and_invalid_negotiation() {
        use idevice::remote_pairing::tunnel::decode_cd_tunnel_response;
        fn frame(mtu: u32, port: u32) -> Vec<u8> {
            let body = json!({"clientParameters":{"address":"fd00::1", "mtu":mtu}, "serverAddress":"fd00::2", "serverRSDPort":port}).to_string();
            let mut data = b"CDTunnel".to_vec(); data.extend_from_slice(&(body.len() as u16).to_be_bytes()); data.extend_from_slice(body.as_bytes()); data
        }
        assert!(decode_cd_tunnel_response(&frame(1500,58783)).is_ok());
        for (mtu,port) in [(0,58783),(65536,58783),(1500,0),(1500,65536)] { assert!(decode_cd_tunnel_response(&frame(mtu,port)).is_err()); }
        let mut data = frame(1500,58783); data.pop(); assert!(decode_cd_tunnel_response(&data).is_err());
        assert!(decode_cd_tunnel_response(b"wrong!").is_err());
    }
    #[tokio::test] async fn missing_identity_requires_explicit_creation_authorization() {
        let mut state = State::default();
        for input in [json!({}), json!({"saved":null,"allowNewIdentity":false})] {
            assert_eq!(operation(&mut state,"prepare",input,None,std::ptr::null_mut()).await.unwrap_err(), "identityCreationRequired");
            assert!(state.identity.is_none());
        }
        assert!(operation(&mut state,"prepare",json!({"saved":null,"allowNewIdentity":true}),None,std::ptr::null_mut()).await.is_ok());
        assert!(state.identity.is_some());
    }
    #[test] fn discovery_set_covers_observed_port_and_full_dynamic_range() {
        let ports = discovery_ports();
        assert_eq!(&ports[..3], &[49152,55021,65535]);
        assert_eq!(ports.len(), 16383);
        assert_eq!(ports.iter().collect::<std::collections::HashSet<_>>().len(), ports.len());
        assert!(!ports.contains(&62078));
        for port in 49152..=65535 { assert_eq!(ports.contains(&port), port != 62078); }
    }
    #[test] fn discovery_classifies_refusal_timeout_wrong_service_separately() {
        use std::io::{Error, ErrorKind};
        assert_eq!(classify_tcp_error(&Error::from(ErrorKind::ConnectionRefused)), "connectionRefused");
        assert_eq!(classify_tcp_error(&Error::from(ErrorKind::TimedOut)), "connectionTimeout");
        assert_eq!(classify_tcp_error(&Error::from(ErrorKind::NetworkUnreachable)), "disconnected");
        assert_eq!(classify_protocol_error(idevice::IdeviceError::UnexpectedResponse("bad magic".into())), "wrongService");
        assert_eq!(classify_protocol_error(idevice::IdeviceError::Timeout), "connectionTimeout");
        assert_eq!(classify_verify_error(idevice::IdeviceError::RemotePairing(idevice::remote_pairing::errors::RemotePairingError::PairVerifyFailed)), "identityRejected");
        assert_eq!(classify_verify_error(idevice::IdeviceError::Socket(Error::from(ErrorKind::ConnectionRefused))), "connectionRefused");
        assert_eq!(classify_verify_error(idevice::IdeviceError::Timeout), "connectionTimeout");
        for code in ["connectionRefused", "connectionTimeout", "wrongService", "disconnected"] {
            let mut failures = DiscoveryFailures::default(); failures.observe(code); assert_eq!(failures.conclusion(),code);
        }
        let mut failures = DiscoveryFailures::default(); failures.observe("connectionRefused"); failures.observe("connectionTimeout");
        assert_eq!(failures.conclusion(),"connectionTimeout"); failures.observe("wrongService"); assert_eq!(failures.conclusion(),"wrongService");
    }
    #[test] fn identity_roundtrip_metadata_and_stability() {
        let identity = Identity::generate(); let restored: Identity = serde_json::from_slice(&serde_json::to_vec(&identity).unwrap()).unwrap();
        assert_eq!(identity.response().unwrap(), restored.response().unwrap());
        let response = identity.response().unwrap();
        assert_eq!(response["identifier"], response["txt"]["identifier"]);
        assert!(!response["txt"]["authTag"].as_str().unwrap().is_empty());
        assert!(!identity.host(&identity.parse().unwrap()).allows_pinless_pairing);
    }
    #[test] fn invalid_identity_rejected() {
        let mut identity = Identity::generate(); identity.pairing = vec![1,2,3]; assert!(identity.parse().is_err());
        let mut identity = Identity::generate(); identity.peer_udid = Some("FAKE-UDID".into()); assert!(identity.parse().is_err());
    }
    #[test] fn abi_failure_is_categorized() { unsafe {
        let value = ze_connection_run(std::ptr::null_mut(), c"unknown".as_ptr(), c"{}".as_ptr(), None, std::ptr::null_mut());
        assert_eq!(CStr::from_ptr(value).to_str().unwrap(), "{\"error\":\"backendUnavailable\"}"); ze_connection_string_free(value);
    }}
    #[test] fn cancellation_before_listen_is_not_lost() { unsafe {
        let session = ze_connection_new(); ze_connection_cancel(session);
        let value = ze_connection_run(session, c"pair".as_ptr(), c"{}".as_ptr(), None, std::ptr::null_mut());
        assert!(CStr::from_ptr(value).to_str().unwrap().contains("error")); ze_connection_string_free(value); ze_connection_free(session);
    }}
}
