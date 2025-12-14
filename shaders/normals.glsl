//------------------------------------------------------------------------------
/// Normal resolution.
/// See also: http://www.thetenthplanet.de/archives/1180
///

mat3 CotangentFrame(vec3 normal, vec3 view_vector, vec2 uv) {
  // Get edge vectors of the pixel triangle.
  vec3 d_view_x = dFdx(view_vector);
  vec3 d_view_y = dFdy(view_vector);
  vec2 d_uv_x = dFdx(uv);
  vec2 d_uv_y = dFdy(uv);

  // Force the UV derivatives to be non-zero using epsilon check.
  // Using == 0.0 is unsafe due to floating point precision.
  const float kEps = 1e-6;
  if (length(d_uv_x) < kEps) {
    d_uv_x = vec2(1.0, 0.0);
  }
  if (length(d_uv_y) < kEps) {
    d_uv_y = vec2(0.0, 1.0);
  }

  // Solve the linear system.
  vec3 view_y_perp = cross(d_view_y, normal);
  vec3 view_x_perp = cross(normal, d_view_x);
  vec3 T = view_y_perp * d_uv_x.x + view_x_perp * d_uv_y.x;
  vec3 B = view_y_perp * d_uv_x.y + view_x_perp * d_uv_y.y;

  // Construct a scale-invariant frame.
  // Important: normalize both T and B, and use the normalized normal.
  float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
  return mat3(normalize(T * invmax), normalize(B * invmax), normalize(normal));
}

vec3 PerturbNormal(sampler2D normal_tex, vec3 normal, vec3 view_vector,
                   vec2 texcoord) {
  vec3 map = texture(normal_tex, texcoord).xyz;

  // Standard unpack: [0,1] -> [-1,1]
  map = map * 2.0 - 1.0;

  // If normal map follows DirectX convention (Y-down), uncomment:
  map.y = -map.y;

  // Reconstruct Z if normal map only stores XY.
  // This is critical for correct bottom-facing surfaces.
  float xy_len_sq = dot(map.xy, map.xy);
  if (xy_len_sq > 1.0) {
    // Out-of-range XY: normalize to avoid artifacts
    map.xy = normalize(map.xy);
    map.z = 0.0;
  } else {
    map.z = sqrt(max(0.0, 1.0 - xy_len_sq));
  }

  mat3 TBN = CotangentFrame(normal, -view_vector, texcoord);
  return normalize(TBN * map);
}