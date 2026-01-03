use rustler::{Binary, Env, NifStruct, OwnedBinary};

// Maximum UDP payload size (conservative value for IPv4)
const MAX_PACKET_SIZE: usize = 1350;

/// Parsed QUIC packet header information
#[derive(NifStruct)]
#[module = "Quichex.Native.PacketHeader"]
pub struct PacketHeader<'a> {
    /// Packet type: "Initial", "Handshake", "ZeroRTT", "Short", "VersionNegotiation", "Retry"
    pub ty: String,
    /// QUIC version number
    pub version: u32,
    /// Destination Connection ID (used for routing packets to connections)
    pub dcid: Binary<'a>,
    /// Source Connection ID
    pub scid: Binary<'a>,
    /// Token (present in Initial packets)
    pub token: Option<Binary<'a>>,
}

/// Parses a QUIC packet header without processing the full packet.
///
/// This is used by the Listener to extract the DCID for routing packets
/// to the correct connection process.
///
/// # Arguments
///
/// * `packet` - The raw QUIC packet bytes
/// * `dcid_len` - Expected destination connection ID length (typically 16)
///
/// # Returns
///
/// PacketHeader struct with parsed header fields, or error string if parsing fails
#[rustler::nif]
pub fn header_info<'a>(
    env: Env<'a>,
    packet: Binary,
    dcid_len: usize,
) -> Result<PacketHeader<'a>, String> {
    // Need a mutable buffer for quiche::Header::from_slice
    let mut buf = packet.as_slice().to_vec();

    // Parse the packet header using quiche
    let hdr = quiche::Header::from_slice(&mut buf, dcid_len)
        .map_err(|e| format!("Failed to parse packet header: {:?}", e))?;

    // Convert packet type to string
    let ty = match hdr.ty {
        quiche::Type::Initial => "Initial",
        quiche::Type::Retry => "Retry",
        quiche::Type::Handshake => "Handshake",
        quiche::Type::ZeroRTT => "ZeroRTT",
        quiche::Type::Short => "Short",
        quiche::Type::VersionNegotiation => "VersionNegotiation",
    }
    .to_string();

    let dcid = to_binary(env, hdr.dcid.as_ref())?;
    let scid = to_binary(env, hdr.scid.as_ref())?;
    let token = match hdr.token {
        Some(tok) => Some(to_binary(env, &tok)?),
        None => None,
    };

    Ok(PacketHeader {
        ty,
        version: hdr.version,
        dcid,
        scid,
        token,
    })
}

/// Generates a version negotiation packet (optional - for Milestone 6)
///
/// This tells the client which QUIC versions the server supports.
#[rustler::nif]
pub fn version_negotiate<'a>(
    env: Env<'a>,
    scid: Binary,
    dcid: Binary,
) -> Result<Binary<'a>, String> {
    let mut owned =
        OwnedBinary::new(MAX_PACKET_SIZE).ok_or_else(|| "Failed to allocate binary".to_string())?;
    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());
    let dcid_ref = quiche::ConnectionId::from_ref(dcid.as_slice());

    let written = quiche::negotiate_version(&scid_ref, &dcid_ref, owned.as_mut_slice())
        .map_err(|e| format!("Version negotiation failed: {:?}", e))?;

    if written < MAX_PACKET_SIZE && !owned.realloc(written) {
        return Err("Failed to shrink binary".to_string());
    }

    Ok(Binary::from_owned(owned, env))
}

/// Generates a stateless retry packet (optional - for Milestone 6)
///
/// Used for address validation to prevent DDoS attacks.
#[rustler::nif]
pub fn retry<'a>(
    env: Env<'a>,
    scid: Binary,
    dcid: Binary,
    new_scid: Binary,
    token: Binary,
    version: u32,
) -> Result<Binary<'a>, String> {
    let mut owned =
        OwnedBinary::new(MAX_PACKET_SIZE).ok_or_else(|| "Failed to allocate binary".to_string())?;
    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());
    let dcid_ref = quiche::ConnectionId::from_ref(dcid.as_slice());
    let new_scid_ref = quiche::ConnectionId::from_ref(new_scid.as_slice());

    let written = quiche::retry(
        &scid_ref,
        &dcid_ref,
        &new_scid_ref,
        token.as_slice(),
        version,
        owned.as_mut_slice(),
    )
    .map_err(|e| format!("Retry packet generation failed: {:?}", e))?;

    if written < MAX_PACKET_SIZE && !owned.realloc(written) {
        return Err("Failed to shrink binary".to_string());
    }

    Ok(Binary::from_owned(owned, env))
}

fn to_binary<'a>(env: Env<'a>, data: &[u8]) -> Result<Binary<'a>, String> {
    let mut owned =
        OwnedBinary::new(data.len()).ok_or_else(|| "Failed to allocate binary".to_string())?;
    owned.as_mut_slice().copy_from_slice(data);
    Ok(Binary::from_owned(owned, env))
}
