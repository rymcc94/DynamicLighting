Shader "Dynamic Lighting/Metallic PBR"
{
    Properties
    {
        _MainTex("Albedo", 2D) = "white" {}
        _MetallicGlossMap("Metallic", 2D) = "black" {}
        _BumpMap("Normal map", 2D) = "bump" {}
        _BumpScale("Normal scale", Range(0,1)) = 0.2
        _OcclusionMap("Occlusion", 2D) = "white" {}
        _OcclusionStrength("Occlusion strength", Range(0,1)) = 0.75
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma shader_feature DYNAMIC_LIGHTING_UNLIT

            #include "UnityCG.cginc"
            #include "DynamicLighting.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv0 : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                float4 color : COLOR;
                float4 tangent : TANGENT;
            };

            struct v2f
            {
                float2 uv0 : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                UNITY_FOG_COORDS(1)
                float4 vertex : SV_POSITION;
                float4 color : COLOR;
                float3 world : TEXCOORD2;
                float3 normal : TEXCOORD3;
                half3 tspace0 : TEXCOORD4; // tangent.x, bitangent.x, normal.x
                half3 tspace1 : TEXCOORD5; // tangent.y, bitangent.y, normal.y
                half3 tspace2 : TEXCOORD6; // tangent.z, bitangent.z, normal.z
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            sampler2D _MetallicGlossMap;
            sampler2D _BumpMap;
            sampler2D _OcclusionMap;
            float _BumpScale;
            float _OcclusionStrength;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv0 = TRANSFORM_TEX(v.uv0, _MainTex);
                o.uv1 = v.uv1;
                o.color = v.color;
                o.normal = UnityObjectToWorldNormal(v.normal);
                o.world = mul(unity_ObjectToWorld, v.vertex).xyz;

                half3 wTangent = UnityObjectToWorldDir(v.tangent.xyz);
                // compute bitangent from cross product of normal and tangent
                half tangentSign = v.tangent.w * unity_WorldTransformParams.w;
                half3 wBitangent = cross(o.normal, wTangent) * tangentSign;
                // output the tangent space matrix
                o.tspace0 = half3(wTangent.x, wBitangent.x, o.normal.x);
                o.tspace1 = half3(wTangent.y, wBitangent.y, o.normal.y);
                o.tspace2 = half3(wTangent.z, wBitangent.z, o.normal.z);

                UNITY_TRANSFER_FOG(o,o.vertex);
                return o;
            }

#if DYNAMIC_LIGHTING_UNLIT

            fixed4 frag(v2f i) : SV_Target
            {
                return tex2D(_MainTex, i.uv0);
            }

#else

            fixed4 frag (v2f i) : SV_Target
            {
                // calculate the lightmap pixel coordinates in advance.
                // clamp uv to 0-1 and multiply by resolution cast to uint.
                uint2 lightmap_uv = saturate(i.uv1) * lightmap_resolution;



                // material parameters
                float3 albedo = tex2D(_MainTex, i.uv0).rgb;
                float4 metallicmap = tex2D(_MetallicGlossMap, i.uv0);
                float metallic = metallicmap.r;
                float roughness = 1.0 - metallicmap.a;
                float ao = tex2D(_OcclusionMap, i.uv0).r;

                half3 bumpmap = UnpackNormal(tex2D(_BumpMap, i.uv0));
                // transform normal from tangent to world space
                half3 worldNormal;
                worldNormal.x = dot(i.tspace0, bumpmap);
                worldNormal.y = dot(i.tspace1, bumpmap);
                worldNormal.z = dot(i.tspace2, bumpmap);




                float3 N = normalize(i.normal + (worldNormal * _BumpScale));
                float3 V = normalize(_WorldSpaceCameraPos - i.world);

                float3 F0 = float3(0.04, 0.04, 0.04);
                F0 = lerp(F0, albedo, metallic);

                // reflectance equation
                float3 Lo = float3(0.0, 0.0, 0.0);
                // iterate over every dynamic light in the scene:
                for (uint k = 0; k < dynamic_lights_count; k++)
                {
                    // get the current light from memory.
                    DynamicLight light = dynamic_lights[k];

                    // calculate the distance between the light source and the fragment.
                    float light_distance = distance(i.world, light.position);

                    // we can use the distance and guaranteed maximum light radius to early out.
                    // confirmed with NVIDIA Quadro K1000M doubling the framerate.
                    if (light_distance > light.radius) continue;

                    // if this renderer has a lightmap we use shadow bits otherwise it's a dynamic object.
                    // if this light is realtime we will skip this step.
                    float map = 1.0;
                    if (lightmap_resolution > 0 && light_is_dynamic(light))
                    {
                        uint shadow_channel = light_get_shadow_channel(light);

                        // fetch the shadow bit and if it's black we can skip the rest of the calculations.
                        // confirmed with NVIDIA Quadro K1000M that this check is cheaper.
                        map = lightmap_pixel(lightmap_uv, shadow_channel);
                        if (map == 0.0) continue;

                        // apply a simple 3x3 sampling with averaged results to the shadow bits.
                        map = lightmap_sample3x3(lightmap_uv, shadow_channel, map);
                    }

                    // calculate the direction between the light source and the fragment.
                    float3 light_direction = normalize(light.position - i.world);

                    // spot lights determine whether we are in the light cone or outside.
                    if (light_is_spotlight(light))
                    {
                        // anything outside of the spot light can and must be skipped.
                        float2 spotlight = light_calculate_spotlight(light, light_direction);
                        if (spotlight.x <= light.outerCutoff)
                            continue;
                        map *= spotlight.y;
                    }
                    else if (light_is_discoball(light))
                    {
                        // anything outside of the spot lights can and must be skipped.
                        float2 spotlight = light_calculate_discoball(light, light_direction);
                        if (spotlight.x <= light.outerCutoff)
                            continue;
                        map *= spotlight.y;
                    }

                    // important attenuation that actually creates the point light with maximum radius.
                    float attenuation = saturate(1.0 - light_distance * light_distance / (light.radius * light.radius)) * light.intensity;

                    // calculate per-light radiance
                    float3 H = normalize(V + light_direction);
                    float3 radiance = light.color * light.intensity * attenuation;

                    // cook-torrance brdf
                    float NDF = DistributionGGX(N, H, roughness);
                    float G = GeometrySmith(N, V, light_direction, roughness);
                    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);

                    float3 kS = F;
                    float3 kD = float3(1.0, 1.0, 1.0) - kS;
                    kD *= 1.0 - metallic;

                    float3 numerator = NDF * G * F;
                    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, light_direction), 0.0) + 0.0001;
                    float3 specular = numerator / denominator;

                    // add to outgoing radiance Lo
                    float NdotL = max(dot(N, light_direction), 0.0);
                    Lo += (kD * albedo / 3.14159265359 + specular) * radiance * NdotL * map;
                }

                float3 color = Lo * lerp(1.0, ao, _OcclusionStrength);

                // apply fog.
                UNITY_APPLY_FOG(i.fogCoord, color);
                return fixed4(color, 1.0);
            }

#endif

            ENDCG
        }
    }
}