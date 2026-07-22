uniform sampler2D g_Texture0; // {"hidden":true}
varying vec2 v_TexCoord;

void main() {
	vec4 source = texture(g_Texture0, v_TexCoord);
	gl_FragColor = vec4(source.b, source.r, source.g, source.a);
}
