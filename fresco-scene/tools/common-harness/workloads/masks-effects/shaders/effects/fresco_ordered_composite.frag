uniform sampler2D g_Texture0; // {"hidden":true}
uniform sampler2D g_Texture1; // {"hidden":true}
varying vec2 v_TexCoord;

void main() {
	vec4 ordered = texture(g_Texture0, v_TexCoord);
	vec4 previous = texture(g_Texture1, v_TexCoord);
	gl_FragColor = vec4(mix(previous.rgb, ordered.rgb, 0.5), 0.75);
}
