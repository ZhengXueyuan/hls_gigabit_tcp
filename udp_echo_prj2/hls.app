<AutoPilot:project xmlns:AutoPilot="com.autoesl.autopilot.project" projectType="C/C++" top="udp_echo" name="udp_echo_prj2" ideType="classic">
    <files>
        <file name="src/udp_echo.cpp" sc="0" tb="false" cflags="" csimflags="" blackbox="false"/>
        <file name="../../tb/udp_echo_tb.cpp" sc="0" tb="1" cflags="-Wno-unknown-pragmas" csimflags="" blackbox="false"/>
    </files>
    <solutions>
        <solution name="solution1" status=""/>
    </solutions>
    <Simulation argv="">
        <SimFlow name="csim" setup="false" optimizeCompile="false" clean="false" ldflags="" mflags=""/>
    </Simulation>
</AutoPilot:project>
