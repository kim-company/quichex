use rustler::{Binary, Env, NifStruct, OwnedBinary};

// Maximum UDP payload size (conservative value for IPv4)
const MAX_PACKET_SIZE: usize = 1350;

/// Parsed QUIC packet header information
#[derive(NifStruct)]
#[module = "Quichex.PacketHeader"]
pub struct PacketHeader {
    /// Packet type: "Initial", "Handshake", "ZeroRTT", "Short", "VersionNegotiation", "Retry"
    pub ty: String,
    /// QUIC version number
    pub version: u32,
    /// Destination Connection ID (used for routing packets to connections)
    pub dcid: Vec<u8>,
    /// Source Connection ID
    pub scid: Vec<u8>,
    /// Token (present in Initial packets)
    pub token: Option<Vec<u8>>,
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
pub fn header_info(
    packet: Binary,
    dcid_len: usize,
) -> Result<PacketHeader, String> {
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

    Ok(PacketHeader {
        ty,
        version: hdr.version,
        dcid: hdr.dcid.to_vec(),
        scid: hdr.scid.to_vec(),
        token: hdr.token.map(|t| t.to_vec()),
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
    let mut out = vec![0u8; MAX_PACKET_SIZE];

    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());
    let dcid_ref = quiche::ConnectionId::from_ref(dcid.as_slice());

    let written = quiche::negotiate_version(&scid_ref, &dcid_ref, &mut out)
        .map_err(|e| format!("Version negotiation failed: {:?}", e))?;

    // Create owned binary and convert to Binary
    let mut owned = OwnedBinary::new(written)
        .ok_or_else(|| "Failed to allocate binary".to_string())?;
    owned.as_mut_slice().copy_from_slice(&out[..written]);

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
    let mut out = vec![0u8; MAX_PACKET_SIZE];

    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());
    let dcid_ref = quiche::ConnectionId::from_ref(dcid.as_slice());
    let new_scid_ref = quiche::ConnectionId::from_ref(new_scid.as_slice());

    let written = quiche::retry(
        &scid_ref,
        &dcid_ref,
        &new_scid_ref,
        token.as_slice(),
        version,
        &mut out,
    )
    .map_err(|e| format!("Retry packet generation failed: {:?}", e))?;

    // Create owned binary and convert to Binary
    let mut owned = OwnedBinary::new(written)
        .ok_or_else(|| "Failed to allocate binary".to_string())?;
    owned.as_mut_slice().copy_from_slice(&out[..written]);

    Ok(Binary::from_owned(owned, env))
}
