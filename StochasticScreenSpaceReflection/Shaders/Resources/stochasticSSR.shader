﻿//Copyright (c) 2015, Charles Greivelding Thomas
//All rights reserved.
//
//Redistribution and use in source and binary forms, with or without
//modification, are permitted provided that the following conditions are met:
//
//* Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//
//* Redistributions in binary form must reproduce the above copyright notice,
//  this list of conditions and the following disclaimer in the documentation
//  and/or other materials provided with the distribution.
//
//THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Shader "Hidden/Stochastic SSR" 
{
	Properties 
	{
		_MainTex ("Base (RGB)", 2D) = "black" {}
	}
	
	CGINCLUDE
	
	#include "UnityCG.cginc"
	#include "UnityPBSLighting.cginc"
    #include "UnityStandardBRDF.cginc"
    #include "UnityStandardUtils.cginc"

	#include "SSRLib.cginc"
	#include "NoiseLib.cginc"
	#include "BRDFLib.cginc"
	#include "RayTraceLib.cginc"

	struct VertexInput 
	{
		float4 vertex : POSITION;
		float2 texcoord : TEXCOORD0;
	};

	struct VertexOutput
	{
		float2 uv : TEXCOORD0;
		float4 vertex : SV_POSITION;
	};

	VertexOutput vert( VertexInput v ) 
	{
		VertexOutput o;
		o.vertex = mul(UNITY_MATRIX_MVP, v.vertex);
		o.uv = v.texcoord;
		return o;
	}


	// Based on https://github.com/playdeadgames/temporal
	void temporal (VertexOutput i, out half4 reflection : SV_Target)
	{	
		float2 uv = i.uv;

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float2 velocity = ReprojectUV(screenPos) - uv;

		float2 prevUV = uv + velocity;

		float4 current = GetSampleColor(_MainTex, uv);
		float4 previous = GetSampleColor(_PreviousBuffer, prevUV);

		float2 du = float2(1.0 / _ScreenParams.x, 0.0);
		float2 dv = float2(0.0, 1.0f / _ScreenParams.y);

		float4 currentTopLeft = GetSampleColor(_MainTex, uv.xy - dv - du);
		float4 currentTopCenter = GetSampleColor(_MainTex, uv.xy - dv);
		float4 currentTopRight = GetSampleColor(_MainTex, uv.xy - dv + du);
		float4 currentMiddleLeft = GetSampleColor(_MainTex, uv.xy - du);
		float4 currentMiddleCenter = GetSampleColor(_MainTex, uv.xy);
		float4 currentMiddleRight = GetSampleColor(_MainTex, uv.xy + du);
		float4 currentBottomLeft = GetSampleColor(_MainTex, uv.xy + dv - du);
		float4 currentBottomCenter = GetSampleColor(_MainTex, uv.xy + dv);
		float4 currentBottomRight = GetSampleColor(_MainTex, uv.xy + dv + du);

		float4 currentMin = min(currentTopLeft, min(currentTopCenter, min(currentTopRight, min(currentMiddleLeft, min(currentMiddleCenter, min(currentMiddleRight, min(currentBottomLeft, min(currentBottomCenter, currentBottomRight))))))));
		float4 currentMax = max(currentTopLeft, max(currentTopCenter, max(currentTopRight, max(currentMiddleLeft, max(currentMiddleCenter, max(currentMiddleRight, max(currentBottomLeft, max(currentBottomCenter, currentBottomRight))))))));

		float scale = _TScale;

		float4 center = (currentMin + currentMax) * 0.5f;
		currentMin = (currentMin - center) * scale + center;
		currentMax = (currentMax - center) * scale + center;

		previous = clamp(previous, currentMin, currentMax); // This works better

		//previous =  max(1e-5,lerp(clamp(previous, cmin, cmax), previous, scale)); // Is nice but too much smearing

		float currentLum = Luminance(current.rgb);
		float previousLum = Luminance(previous.rgb);
		float unbiasedDiff = abs(currentLum - previousLum) / max(currentLum, max(previousLum, 0.2f));
		float unbiasedWeight = 1.0 - unbiasedDiff;
		float unbiasedWeightSqr = sqr(unbiasedWeight);

		float response = lerp(_TMinResponse, _TMaxResponse, unbiasedWeightSqr);

    	reflection = lerp(current, previous, response);
	}

	float4 resolve ( VertexOutput i ) : SV_Target
	{
		float2 uv = i.uv;
		int2 pos = uv * _ScreenParams.xy;

		float4 worldNormal = GetNormal (uv);
		float3 viewNormal = GetViewNormal (worldNormal);
		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness (specular.a);

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float3 worldPos = GetWorlPos(screenPos);
		float3 viewPos = GetViewPos(screenPos);
		float3 viewDir = GetViewDir(worldPos);

		// [Jimenez 2014] "Next Generation Post Processing In Call Of Duty Advanced Warfare"  
		/*float2x2 offsetRotationMatrix;
		{
			float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
			float interleavedGradientNoise = frac(magic.z * frac(dot(pos, magic.xy)));
			float2 offsetRotation;
			sincos(2.0 * PI * interleavedGradientNoise, offsetRotation.y, offsetRotation.x);
			offsetRotationMatrix = float2x2(offsetRotation.x, offsetRotation.y, -offsetRotation.y, offsetRotation.x);
		}*/

		float2 offsetRotation = Step3T(pos, _Time.y * _UseTemporal) * 2.0 - 1.0;
		float2x2 offsetRotationMatrix = float2x2(offsetRotation.x, offsetRotation.y, -offsetRotation.y, offsetRotation.x);

		int NumResolve = 1;
		if(_RayReuse == 1)
			NumResolve = 4;

		float coneTangent = roughness * (1.0 + _BRDFBias);
		float NdotV = saturate(dot(worldNormal, -viewDir));
		coneTangent *= lerp(saturate(NdotV * 2.0), 1.0, sqrt(roughness));// * NdotV;

		// http://roar11.com/2015/07/screen-space-glossy-reflections/
		float specularPower = RoughnessToSpecPower(roughness);
		float coneTheta = specularPowerToConeAngle(specularPower) * 0.5f;
		//

		float maxMipLevel = (float)_MaxMipMap - 1.0f;

		float4 result = 0.0f;
        float weightSum = 0.0f;	
        for(int i = 0; i < NumResolve; i++)
        {
			float2 offsetUV = offset[i] * 1.0 / _BufferSize.xy;
			offsetUV =  mul(offsetRotationMatrix, offsetUV);

            // "uv" is the location of the current (or "local") pixel. We want to resolve the local pixel using
            // intersections spawned from neighboring pixels. The neighboring pixel is this one:
			float2 neighborUv = uv + offsetUV;

            // Now we fetch the intersection point and the PDF that the neighbor's ray hit.
            float4 hitPacked = tex2Dlod(_RayCast, float4(neighborUv,0,0));
            float2 hitUv = hitPacked.xy;
            float hitZ = hitPacked.z;
            float hitPDF = hitPacked.w;
			float hitMask = tex2Dlod(_RayCastMask, float4(neighborUv,0,0)).r;

			float3 hitViewPos = GetViewPos(GetScreenPos(hitUv, hitZ));

            // We assume that the hit point of the neighbor's ray is also visible for our ray, and we blindly pretend
            // that the current pixel shot that ray. To do that, we treat the hit point as a tiny light source. To calculate
            // a lighting contribution from it, we evaluate the BRDF. Finally, we need to account for the probability of getting
            // this specific position of the "light source", and that is approximately 1/PDF, where PDF comes from the neighbor.
            // Finally, the weight is BRDF/PDF. BRDF uses the local pixel's normal and roughness, but PDF comes from the neighbor.
			float weight = 1.0;
			if(_UseNormalization == 1)
				 weight =  max(1e-5, max(1e-5,BRDF(normalize(-viewPos) /*V*/, normalize(hitViewPos - viewPos) /*L*/, viewNormal /*N*/, roughness)) / hitPDF);

			//float intersectionCircleRadius = coneTangent * length(hitUv - neighborUv);
			//float mip = clamp(log2(intersectionCircleRadius * _BufferSize.y), 0, maxMipLevel);

			// http://roar11.com/2015/07/screen-space-glossy-reflections/
			float2 deltaP = hitUv - neighborUv;
			float adjacentLength = length(deltaP);
			float oppositeLength = isoscelesTriangleOpposite(adjacentLength, coneTheta);
 
			// calculate in-radius of the isosceles triangle
			float incircleSize = isoscelesTriangleInRadius(oppositeLength, adjacentLength);
 
			// convert the in-radius into screen size then check what power N to raise 2 to reach it - that power N becomes mip level to sample from
			float mip = clamp(log2(incircleSize * max(_BufferSize.x, _BufferSize.y)), 0.0, maxMipLevel);
			//

			float4 sampleColor = float4(tex2Dlod(_MainTex, float4(hitUv, 0, mip)).xyz, RayAttenBorder (hitUv, _EdgeFactor) * hitMask);

			if(_Fireflies == 1)
				sampleColor.rgb /= 1 + Luminance(sampleColor.rgb);

            result += sampleColor * weight;
            weightSum += weight;
        }
		// Sometimes the weight sum will be zero if no usable samples can be stolen from neighbors. You may need clamps in other places too, e.g. in the BRDF or the PDF. Play around and see.
        result /= max(1e-5, weightSum);

		if(_Fireflies == 1)
			result.rgb /= 1 - Luminance(result.rgb);

    	return result;
	}

	void rayCast ( VertexOutput i, 	out half4 outRayCast : SV_Target0, out half4 outRayCastMask : SV_Target1) 
	{	
		float2 uv = i.uv;
		int2 pos = uv * _ScreenParams.xy / 2.0;

		float4 worldNormal = GetNormal (uv);
		float3 viewNormal = GetViewNormal (worldNormal);
		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness (specular.a);

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float3 viewPos = GetViewPos(screenPos);

		float2 jitter = 0.0;
		if(_NoiseType == 0)
			jitter = Noise(pos, _Time.y * _UseTemporal);
		else if (_NoiseType == 1)
			jitter = Step3T(pos, _Time.y * _UseTemporal);

		float2 Xi =  jitter;

		Xi.y = lerp(Xi.y, 0.0, _BRDFBias);

		float4 H = TangentToWorld(viewNormal, ImportanceSampleGGX(Xi, roughness));
		float3 R = reflect(normalize(viewPos), H.xyz);

		jitter += 0.5f;

		float stepSize = (1.0f / (float)_NumSteps);
		stepSize = stepSize * (jitter.x + jitter.y) + stepSize;

		float2 rayTraceHit = 0.0f;
		float rayTraceZ = 0.0f;
		float rayPDF = 0.0f;
		float rayMask = 0.0f;
		float4 rayTrace = RayMarch(_CameraDepthBuffer, _ProjectionMatrix, R, _NumSteps, viewPos, screenPos, uv, stepSize);

		rayTraceHit = rayTrace.xy;
		rayTraceZ = rayTrace.z;
		rayPDF = H.w;
		rayMask = rayTrace.w;

		outRayCast = float4(float3(rayTraceHit, rayTraceZ), rayPDF);
		outRayCastMask = rayMask;
	}

	float4 frag( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float4 cubemap = GetCubeMap (uv);

		float4 sceneColor = tex2D(_MainTex,  uv);
		sceneColor.rgb = max(1e-5, sceneColor.rgb - cubemap.rgb);

		return sceneColor;
	}

	float4 recursive( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float2 velocity = ReprojectUV(screenPos) - uv;

		float2 prevUV = uv + velocity;

		float4 cubemap = GetCubeMap (uv);

		float4 sceneColor = tex2D(_MainTex,  prevUV);

		return sceneColor;
	}

	float4 combine( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;

		float depth = GetDepth(_CameraDepthTexture, uv);
		float3 screenPos = GetScreenPos(uv, depth);
		float3 worldPos = GetWorlPos(screenPos);

		float3 cubemap = GetCubeMap (uv);
		float4 worldNormal = GetNormal (uv);

		float4 diffuse =  GetAlbedo(uv);
		float occlusion = diffuse.a;
		float4 specular = GetSpecular (uv);
		float roughness = GetRoughness(specular.a);

		float4 sceneColor = tex2D(_MainTex,  uv);
		sceneColor.rgb = max(1e-5, sceneColor.rgb - cubemap.rgb);

		float4 reflection = GetSampleColor(_ReflectionBuffer, uv);

		float3 viewDir = GetViewDir(worldPos);
		float NdotV = saturate(dot(worldNormal, -viewDir));

		float3 reflDir = normalize( reflect( -viewDir, worldNormal ) );
		float fade = saturate(dot(-viewDir, reflDir) * 2.0);
		float mask = sqr(reflection.a) * fade;

		float oneMinusReflectivity;
		diffuse.rgb = EnergyConservationBetweenDiffuseAndSpecular(diffuse, specular.rgb, oneMinusReflectivity);

        UnityLight light;
        light.color = 0;
        light.dir = 0;
        light.ndotl = 0;

        UnityIndirect ind;
        ind.diffuse = 0;
        ind.specular = reflection;

		if(_UseFresnel == 1)													
			reflection.rgb = UNITY_BRDF_PBS (0, specular.rgb, oneMinusReflectivity, 1-roughness, worldNormal, -viewDir, light, ind).rgb;

		reflection.rgb *= occlusion;

		if(_DebugPass == 0)
			sceneColor.rgb += lerp(cubemap.rgb, reflection.rgb, mask); // Combine reflection and cubemap and add it to the scene color 
		else if(_DebugPass == 1)
			sceneColor.rgb = reflection.rgb * mask;
		else if(_DebugPass == 2)
			sceneColor.rgb = cubemap;
		else if(_DebugPass == 3)
			sceneColor.rgb = lerp(cubemap.rgb, reflection.rgb, mask);
		else if(_DebugPass == 4)
			sceneColor = mask;
		else if(_DebugPass == 5)
			sceneColor.rgb += lerp(0.0f, reflection.rgb, mask);
		else if(_DebugPass == 6)
			sceneColor.rgb = GetSampleColor(_RayCast, uv);

		return sceneColor;
	}

	float4 depth(VertexOutput i ) : SV_Target
	{
		float2 uv = i.uv;
		return tex2D(_CameraDepthTexture, uv);
	}

	static const int2 offsets[7] = {{-3, -3}, {-2, -2}, {-1, -1}, {0, 0}, {1, 1}, {2, 2}, {3, 3}};

	static const float weights[7] = {0.001f, 0.028f, 0.233f, 0.474f, 0.233f, 0.028f, 0.001f};

	float4 _GaussianDir;
	float4 _MipMapBufferSize;
	int	_MipMapCount;

	float4 mipMapBlur( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;
		int2 pos = uv * _MipMapBufferSize.xy;

		float2 jitter = Step3T(pos, _Time.y * _UseTemporal) * 0.25 + 0.5;
		float2x2 offsetRotationMatrix = float2x2(jitter.x, jitter.y, -jitter.y, jitter.x);

		int NumSamples = 7;

		float4 result = 0.0;
		for(int i = 0; i < NumSamples; i++)
		{
			float2 offset = 0.0;

			if(_JitterMipMap == 1)
			{
				offset =  offsets[i] * 1.0 / _MipMapBufferSize.xy * _GaussianDir;
				offset = mul(offsetRotationMatrix, offset);
			}
			else
				offset = offsets[i] * 1.0 / _MipMapBufferSize.xy * _GaussianDir;

			float4 sampleColor = tex2Dlod(_MainTex, float4(uv + offset, 0, _MipMapCount));
			if(_Fireflies == 1)
				sampleColor.rgb /= 1 + Luminance(sampleColor.rgb);

			result += sampleColor * weights[i];
		}

		if(_Fireflies == 1)
			result /= 1 - Luminance(result.rgb);

		return result;
	}

	float4 debug( VertexOutput i ) : SV_Target
	{	 
		float2 uv = i.uv;
		float4 specular = GetSpecular (uv);

		return tex2Dlod(_ReflectionBuffer, float4(uv,0, uv.x * 11));
	}

	ENDCG 
	
	SubShader 
	{
		ZTest Always Cull Off ZWrite Off

		//0
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment resolve
			ENDCG
		}
		//1
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment frag
			ENDCG
		}
		//2
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment combine
			ENDCG
		}
		//3
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment rayCast
			ENDCG
		}
		//4
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3

			#pragma vertex vert
			#pragma fragment depth
			ENDCG
		}
		//5
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3

			#pragma vertex vert
			#pragma fragment temporal
			ENDCG
		}
		//6
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3

			#pragma vertex vert
			#pragma fragment mipMapBlur
			ENDCG
		}
		//7
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment debug
			ENDCG
		}
		//8
		Pass 
		{
			CGPROGRAM
			#pragma target 3.0

			#pragma exclude_renderers nomrt gles xbox360 ps3 xbox360 ps3

			#pragma vertex vert
			#pragma fragment recursive
			ENDCG
		}
	}
	Fallback Off
}