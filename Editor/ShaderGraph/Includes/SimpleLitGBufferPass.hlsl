
void InitializeInputData(Varyings input, SurfaceDescription surfaceDescription, out InputData inputData)
{
    inputData = (InputData)0;

    inputData.positionWS = input.positionWS;
    inputData.positionCS = input.positionCS;

    #ifdef _NORMALMAP
        // IMPORTANT! If we ever support Flip on double sided materials ensure bitangent and tangent are NOT flipped.
        float crossSign = (input.tangentWS.w > 0.0 ? 1.0 : -1.0) * GetOddNegativeScale();
        float3 bitangent = crossSign * cross(input.normalWS.xyz, input.tangentWS.xyz);

        inputData.tangentToWorld = half3x3(input.tangentWS.xyz, bitangent.xyz, input.normalWS.xyz);
        #if _NORMAL_DROPOFF_TS
            inputData.normalWS = TransformTangentToWorld(surfaceDescription.NormalTS, inputData.tangentToWorld);
        #elif _NORMAL_DROPOFF_OS
            inputData.normalWS = TransformObjectToWorldNormal(surfaceDescription.NormalOS);
        #elif _NORMAL_DROPOFF_WS
            inputData.normalWS = surfaceDescription.NormalWS;
        #endif
    #else
        inputData.normalWS = input.normalWS;
    #endif
    inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
#if UNITY_VERSION >= 202220
    inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
#else
    inputData.viewDirectionWS = SafeNormalize(GetWorldSpaceViewDir(input.positionWS));
#endif

#if defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactorAndVertexLight.x);
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    // bakedGI / shadowMask are filled in by InitializeBakedGIData() below, after the surface is known.

    #if defined(DEBUG_DISPLAY)
    #if defined(DYNAMICLIGHTMAP_ON)
    inputData.dynamicLightmapUV = input.dynamicLightmapUV.xy;
    #endif
    #if defined(LIGHTMAP_ON)
    inputData.staticLightmapUV = input.staticLightmapUV;
    #else
    inputData.vertexSH = input.sh;
    #endif
    #if defined(USE_APV_PROBE_OCCLUSION)
    inputData.probeOcclusion = input.probeOcclusion;    // FIX: added, APV probe occlusion debug data
    #endif
    #endif
}

// FIX: added. Mirrors URP's PBRForwardPass so lightmaps, Adaptive Probe Volumes and screen space
// irradiance are all sampled the way the rest of URP does. The old code called SAMPLE_GI with the
// legacy lightmap/SH signature unconditionally, which silently skipped APV entirely.
void InitializeBakedGIData(Varyings input, inout InputData inputData)
{
#if defined(_SCREEN_SPACE_IRRADIANCE)
    inputData.bakedGI = SAMPLE_GI(_ScreenSpaceIrradiance, input.positionCS.xy);
#elif defined(DYNAMICLIGHTMAP_ON)
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.dynamicLightmapUV.xy, input.sh, inputData.normalWS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(input.staticLightmapUV);
#elif !defined(LIGHTMAP_ON) && (defined(PROBE_VOLUMES_L1) || defined(PROBE_VOLUMES_L2))
    inputData.bakedGI = SAMPLE_GI(input.sh,
        GetAbsolutePositionWS(inputData.positionWS),
        inputData.normalWS,
        inputData.viewDirectionWS,
        input.positionCS.xy,
        input.probeOcclusion,
        inputData.shadowMask);
#else
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.sh, inputData.normalWS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(input.staticLightmapUV);
#endif
}

PackedVaryings vert(Attributes input)
{
    Varyings output = (Varyings)0;
    output = BuildVaryings(input);
    PackedVaryings packedOutput = (PackedVaryings)0;
    packedOutput = PackVaryings(output);
    return packedOutput;
}

// FIX: was gated on UNITY_VERSION >= 600010, i.e. the Unity editor version, but the GBuffer output API
// is a URP *package* change. Branch on the include guard of the file the sub-target actually included -
// GBufferOutput.hlsl defines UNIVERSAL_GBUFFEROUTPUT_INCLUDED, and URP >= 17.3 reaches it through
// UnityGBuffer.hlsl too. That makes this agree with URP no matter which Unity/URP pair is in use.
#if defined(UNIVERSAL_GBUFFEROUTPUT_INCLUDED)
GBufferFragOutput frag(PackedVaryings packedInput)
#else
FragmentOutput frag(PackedVaryings packedInput)
#endif
{
    Varyings unpacked = UnpackVaryings(packedInput);
    UNITY_SETUP_INSTANCE_ID(unpacked);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(unpacked);
    SurfaceDescription surfaceDescription = BuildSurfaceDescription(unpacked);

    #if _ALPHATEST_ON
        half alpha = surfaceDescription.Alpha;
        clip(alpha - surfaceDescription.AlphaClipThreshold);
    #elif _SURFACE_TYPE_TRANSPARENT
        half alpha = surfaceDescription.Alpha;
    #else
        half alpha = 1;
    #endif

#if UNITY_VERSION >= 202220
    #if defined(LOD_FADE_CROSSFADE) && USE_UNITY_CROSSFADE
        LODFadeCrossFade(unpacked.positionCS);
    #endif
#endif

    InputData inputData;
    InitializeInputData(unpacked, surfaceDescription, inputData);
    // TODO: Mip debug modes would require this, open question how to do this on ShaderGraph.
    //SETUP_DEBUG_TEXTURE_DATA(inputData, unpacked.uv, _MainTex);

    #ifdef _SPECULAR_COLOR
        float3 specular = surfaceDescription.Specular;
        //float metallic = 1;
    #else
        float3 specular = 0;
        //float metallic = surfaceDescription.Metallic;
    #endif

    // Since we are using SurfaceData in this pass we should include the normal check
    half3 normalTS = half3(0, 0, 0);
    #if defined(_NORMALMAP) && defined(_NORMAL_DROPOFF_TS)
        normalTS = surfaceDescription.NormalTS;
    #endif

#ifdef _DBUFFER
    // ApplyDecal needs modifiable values for metallic and occlusion
    // but they end up not being used, so feed them a throwaway value
    float throwaway = 0.0;
    ApplyDecal(unpacked.positionCS,
        surfaceDescription.BaseColor,
        specular,
        inputData.normalWS,
        /*metallic,*/
        throwaway,
        /*surfaceDescription.Occlusion,*/
        throwaway,
        surfaceDescription.Smoothness);
#endif

    // in SimpleLitForwardPass GlobalIllumination (and temporarily UniversalBlinnPhong) are called inside UniversalFragmentBlinnPhong
    // in Deferred rendering we store the sum of these values (and of emission as well) in the GBuffer
    //BRDFData brdfData;
    //InitializeBRDFData(surfaceDescription.BaseColor, metallic, specular, surfaceDescription.Smoothness, alpha, brdfData);

    SurfaceData surface;
    surface.albedo              = surfaceDescription.BaseColor;
    surface.metallic            = 0.0; //saturate(metallic);
    surface.specular            = specular;
    surface.smoothness          = saturate(surfaceDescription.Smoothness);
    surface.occlusion           = 1.0; //surfaceDescription.Occlusion,
    surface.emission            = surfaceDescription.Emission;
    surface.alpha               = saturate(alpha);
    surface.normalTS            = normalTS;
    surface.clearCoatMask       = 0;
    surface.clearCoatSmoothness = 1;

#if UNITY_VERSION >= 202210
    surface.albedo = AlphaModulate(surface.albedo, surface.alpha);
#endif

    InitializeBakedGIData(unpacked, inputData);

    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, inputData.shadowMask);
    //half3 color = GlobalIllumination(brdfData, inputData.bakedGI, surfaceDescription.Occlusion, inputData.positionWS, inputData.normalWS, inputData.viewDirectionWS);
    half4 color = half4(inputData.bakedGI * surface.albedo + surface.emission, surface.alpha);

    //return BRDFDataToGbuffer(brdfData, inputData, surfaceDescription.Smoothness, surfaceDescription.Emission + color, surfaceDescription.Occlusion);
#if defined(UNIVERSAL_GBUFFEROUTPUT_INCLUDED)
    return PackGBuffersSurfaceData(surface, inputData, color.rgb);
#else
    return SurfaceDataToGbuffer(surface, inputData, color.rgb, kLightingSimpleLit);
#endif
}
